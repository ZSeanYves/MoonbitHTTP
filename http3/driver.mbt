///|
/// Actions emitted by the HTTP/3 stream driver. The driver never writes a
/// socket; a QUIC adapter sends `SendOnStream` and applies reset/close actions.
pub(all) enum H3DriverAction {
  Event(H3Action)
  SendOnStream(Int64, Bytes, Bool)
  ResetStream(Int64, H3ErrorCode)
  CloseConnection(H3ErrorCode)
  QpackStreamReady(Int64)
} derive(Eq, Debug)

///|
fn h3_driver_join(parts : Array[Bytes]) -> Bytes {
  let mut length = 0
  for part in parts {
    length += part.length()
  }
  let output = FixedArray::make(length, b'\x00')
  let mut offset = 0
  for part in parts {
    for byte in part {
      output[offset] = byte
      offset += 1
    }
  }
  output.unsafe_reinterpret_as_bytes()
}

///|
pub struct Http3Driver {
  connection : Http3Connection
  decoders : Map[Int64, Http3FrameDecoder]
  kinds : Map[Int64, H3UnidirectionalStream]
  prefixes : Map[Int64, Array[Byte]]
  blocked_frames : Map[Int64, Array[Http3Frame]]
  mut blocked_bytes : Int
  pending_fin : Map[Int64, Bool]
  mut failure : Http3Error?
  local_control_stream : Int64
  local_qpack_encoder_stream : Int64
  local_qpack_decoder_stream : Int64
}

///|
fn h3_driver_local_uni_ids(role : H3Role) -> (Int64, Int64, Int64) {
  if role == H3Client {
    (2L, 6L, 10L)
  } else {
    (3L, 7L, 11L)
  }
}

///|
pub fn Http3Driver::new(
  role : H3Role,
  limits? : @types.Limits = @types.Limits::defaults(),
  qpack_limits? : QpackLimits = QpackLimits::defaults(),
) -> Result[Http3Driver, Http3Error] {
  let connection = match Http3Connection::new(role, limits~, qpack_limits~) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (control, encoder, decoder) = h3_driver_local_uni_ids(role)
  Ok({
    connection,
    decoders: Map([]),
    kinds: Map([]),
    prefixes: Map([]),
    blocked_frames: Map([]),
    blocked_bytes: 0,
    pending_fin: Map([]),
    failure: None,
    local_control_stream: control,
    local_qpack_encoder_stream: encoder,
    local_qpack_decoder_stream: decoder,
  })
}

///|
pub fn Http3Driver::connection(self : Http3Driver) -> Http3Connection {
  self.connection
}

///|
pub fn Http3Driver::failure(self : Http3Driver) -> Http3Error? {
  self.failure
}

///|
pub fn Http3Driver::local_control_stream(self : Http3Driver) -> Int64 {
  self.local_control_stream
}

///|
pub fn Http3Driver::local_qpack_encoder_stream(self : Http3Driver) -> Int64 {
  self.local_qpack_encoder_stream
}

///|
pub fn Http3Driver::local_qpack_decoder_stream(self : Http3Driver) -> Int64 {
  self.local_qpack_decoder_stream
}

///|
pub fn Http3Driver::initial_control_bytes(
  self : Http3Driver,
  enable_connect_protocol? : Bool = false,
) -> Result[Bytes, Http3Error] {
  encode_http3_frame(
    self.connection.local_settings_frame(enable_connect_protocol~),
  )
}

///|
fn Http3Driver::h3_driver_fail(
  self : Http3Driver,
  error : Http3Error,
) -> Result[Array[H3DriverAction], Http3Error] {
  self.failure = Some(error)
  Err(error)
}

///|
fn Http3Driver::h3_driver_push_actions(
  self : Http3Driver,
  stream_id : Int64,
  actions : Array[H3Action],
) -> Result[Array[H3DriverAction], Http3Error] {
  let output : Array[H3DriverAction] = []
  for action in actions {
    output.push(Event(action))
    match action {
      H3SendQpackEncoderInstruction(bytes) =>
        output.push(SendOnStream(self.local_qpack_encoder_stream, bytes, false))
      H3SendQpackDecoderInstruction(bytes) =>
        output.push(SendOnStream(self.local_qpack_decoder_stream, bytes, false))
      _ => ()
    }
  }
  ignore(stream_id)
  Ok(output)
}

///|
fn Http3Driver::h3_driver_replay_blocked(
  self : Http3Driver,
  stream_id : Int64,
) -> Result[Array[H3DriverAction], Http3Error] {
  let frames = match self.blocked_frames.get(stream_id) {
    Some(value) => value.copy()
    None => return Ok([])
  }
  for frame in frames {
    self.blocked_bytes -= h3_driver_blocked_frame_bytes(frame)
  }
  let output : Array[H3DriverAction] = []
  for frame in frames {
    let actions = match
      self.connection.receive_request_frame(stream_id, frame) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if actions.is_empty() {
      continue
    }
    let converted = match self.h3_driver_push_actions(stream_id, actions) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    output.append(converted)
  }
  self.blocked_frames.remove(stream_id)
  if self.pending_fin.get(stream_id) is Some(_) {
    match self.connection.finish_request_stream(stream_id) {
      Ok(_) => self.pending_fin.remove(stream_id)
      Err(error) => return Err(error)
    }
  }
  Ok(output)
}

///|
/// A blocked field section retains its decoded frame object until QPACK
/// encoder instructions arrive. Count the encoded section and the frame
/// prefix against the shared buffer budget so repeated blocked sections cannot
/// grow an unbounded per-stream queue.
fn h3_driver_blocked_frame_bytes(frame : Http3Frame) -> Int {
  let payload_bytes = match frame {
    H3Headers(section) => section.length()
    H3PushPromise(_, section) => section.length()
    _ => 0
  }
  payload_bytes + 2
}

///|
fn Http3Driver::h3_driver_new_decoder(
  self : Http3Driver,
) -> Result[Http3FrameDecoder, Http3Error] {
  Http3FrameDecoder::new(
    max_buffer_bytes=self.connection.limits.max_buffer_bytes,
    max_payload_bytes=self.connection.limits.max_header_bytes,
  )
}

///|
fn Http3Driver::h3_driver_feed_decoder(
  self : Http3Driver,
  stream_id : Int64,
  bytes : BytesView,
  fin : Bool,
) -> Result[Array[Http3Frame], Http3Error] {
  guard self.decoders.get(stream_id) is Some(decoder) else {
    return Err(
      Http3StreamError(
        stream_id,
        H3StreamCreationError,
        "stream decoder is missing",
      ),
    )
  }
  match decoder.feed(bytes) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let frames : Array[Http3Frame] = []
  while true {
    let next = match decoder.next() {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    match next {
      Some(frame) => frames.push(frame)
      None => break
    }
  }
  if fin {
    match decoder.finish() {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  Ok(frames)
}

///|
fn Http3Driver::h3_driver_handle_uni(
  self : Http3Driver,
  stream_id : Int64,
  bytes : Bytes,
  fin : Bool,
) -> Result[Array[H3DriverAction], Http3Error] {
  let prefix = match self.prefixes.get(stream_id) {
    Some(value) => value
    None => []
  }
  for byte in bytes {
    prefix.push(byte)
  }
  let prefix_bytes = Bytes::from_array(prefix)
  let registered = match self.kinds.get(stream_id) {
    Some(kind) => Some((kind, 0))
    None =>
      match
        self.connection.register_remote_unidirectional(stream_id, prefix_bytes) {
        Ok(value) => Some(value)
        Err(Http3NeedMoreInput) => {
          if fin {
            return self.h3_driver_fail(
              Http3UnexpectedEof("unidirectional stream type is truncated"),
            )
          }
          self.prefixes.set(stream_id, prefix)
          return Ok([])
        }
        Err(error) => return Err(error)
      }
  }
  let (kind, consumed) = match registered {
    Some(value) => value
    None => return Ok([])
  }
  self.kinds.set(stream_id, kind)
  let decoder_bytes = if self.prefixes.get(stream_id) is Some(_) {
    prefix_bytes[consumed:].to_owned()
  } else if consumed == 0 {
    bytes
  } else {
    prefix_bytes[consumed:].to_owned()
  }
  self.prefixes.remove(stream_id)
  match kind {
    H3ControlStream => {
      let decoder = match self.decoders.get(stream_id) {
        Some(value) => value
        None => {
          let value = match self.h3_driver_new_decoder() {
            Ok(result) => result
            Err(error) => return Err(error)
          }
          self.decoders.set(stream_id, value)
          value
        }
      }
      ignore(decoder)
      let frames = match
        self.h3_driver_feed_decoder(stream_id, decoder_bytes, fin) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let output : Array[H3DriverAction] = []
      for frame in frames {
        let actions = match self.connection.receive_control_frame(frame) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let converted = match self.h3_driver_push_actions(stream_id, actions) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        output.append(converted)
      }
      if fin {
        match self.connection.remote_unidirectional_closed(stream_id) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
      }
      Ok(output)
    }
    H3QpackEncoderStream => {
      let ready = match
        self.connection.feed_qpack_encoder_stream(decoder_bytes) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let output : Array[H3DriverAction] = []
      for stream in ready {
        output.push(QpackStreamReady(stream))
        let replayed = match self.h3_driver_replay_blocked(stream) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        output.append(replayed)
      }
      if fin {
        return self.h3_driver_fail(
          Http3ConnectionError(
            H3ClosedCriticalStream,
            "peer closed QPACK encoder stream",
          ),
        )
      }
      Ok(output)
    }
    H3QpackDecoderStream => {
      match self.connection.feed_qpack_decoder_stream(decoder_bytes) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      if fin {
        return self.h3_driver_fail(
          Http3ConnectionError(
            H3ClosedCriticalStream,
            "peer closed QPACK decoder stream",
          ),
        )
      }
      Ok([])
    }
    H3PushStream(_) | H3UnknownStream(_) => {
      // Completed non-critical unidirectional streams do not need a registry
      // entry after their bytes have been ignored. Retaining every historical
      // unknown stream would turn a long-lived connection into an unbounded
      // stream-ID map.
      if fin {
        self.kinds.remove(stream_id)
      }
      Ok([])
    }
  }
}

///|
/// Feeds one QUIC stream fragment into the HTTP/3 state machine. Input may be
/// arbitrarily fragmented; a FIN verifies that no partial frame remains.
pub fn Http3Driver::on_stream_data(
  self : Http3Driver,
  stream_id : Int64,
  bytes : Bytes,
  fin : Bool,
) -> Result[Array[H3DriverAction], Http3Error] {
  if self.failure is Some(error) {
    return Err(error)
  }
  if stream_id < 0L {
    return self.h3_driver_fail(
      Http3ConnectionError(H3StreamCreationError, "negative stream ID"),
    )
  }
  if (stream_id & 2L) != 0L {
    return self.h3_driver_handle_uni(stream_id, bytes, fin)
  }
  if self.connection.stream_phase(stream_id) is None {
    match self.connection.accept_request_stream(stream_id) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  if self.decoders.get(stream_id) is None {
    let decoder = match self.h3_driver_new_decoder() {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    self.decoders.set(stream_id, decoder)
  }
  let frames = match self.h3_driver_feed_decoder(stream_id, bytes, fin) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let output : Array[H3DriverAction] = []
  for frame in frames {
    let actions = match
      self.connection.receive_request_frame(stream_id, frame) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if actions.is_empty() {
      let frame_bytes = h3_driver_blocked_frame_bytes(frame)
      if frame_bytes > self.connection.limits.max_buffer_bytes ||
        self.blocked_bytes >
        self.connection.limits.max_buffer_bytes - frame_bytes {
        return Err(
          Http3LimitExceeded(
            "HTTP/3 blocked QPACK frames",
            self.connection.limits.max_buffer_bytes,
          ),
        )
      }
      let queued = match self.blocked_frames.get(stream_id) {
        Some(value) => value
        None => {
          self.blocked_frames.set(stream_id, [])
          match self.blocked_frames.get(stream_id) {
            Some(value) => value
            None =>
              return Err(
                Http3StreamError(
                  stream_id,
                  H3InternalError,
                  "failed to allocate blocked QPACK section",
                ),
              )
          }
        }
      }
      queued.push(frame)
      self.blocked_bytes += frame_bytes
    } else {
      let converted = match self.h3_driver_push_actions(stream_id, actions) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      output.append(converted)
    }
  }
  if fin {
    if self.blocked_frames.get(stream_id) is Some(_) {
      self.pending_fin.set(stream_id, true)
    } else {
      match self.connection.finish_request_stream(stream_id) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
    }
    self.decoders.remove(stream_id)
  }
  Ok(output)
}

///|
pub fn Http3Driver::open_request_stream(
  self : Http3Driver,
  request_method? : String? = None,
) -> Result[Int64, Http3Error] {
  self.connection.open_request_stream(request_method~)
}

///|
/// Returns the bytes/actions needed to open the three local critical
/// unidirectional streams.  The QUIC adapter is responsible for creating the
/// streams with these IDs before sending the returned fragments.
pub fn Http3Driver::initial_stream_actions(
  self : Http3Driver,
  enable_connect_protocol? : Bool = false,
) -> Result[Array[H3DriverAction], Http3Error] {
  let control = match self.initial_control_bytes(enable_connect_protocol~) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let control_type = match @quic.QuicVarInt::new(H3_STREAM_CONTROL) {
    Ok(value) => value.encode()
    Err(_) =>
      return Err(
        Http3ConnectionError(
          H3StreamCreationError,
          "invalid control stream type",
        ),
      )
  }
  let encoder_type = match @quic.QuicVarInt::new(H3_STREAM_QPACK_ENCODER) {
    Ok(value) => value.encode()
    Err(_) =>
      return Err(
        Http3ConnectionError(H3StreamCreationError, "invalid QPACK stream type"),
      )
  }
  let decoder_type = match @quic.QuicVarInt::new(H3_STREAM_QPACK_DECODER) {
    Ok(value) => value.encode()
    Err(_) =>
      return Err(
        Http3ConnectionError(H3StreamCreationError, "invalid QPACK stream type"),
      )
  }
  Ok([
    SendOnStream(
      self.local_control_stream,
      h3_driver_join([control_type, control]),
      false,
    ),
    SendOnStream(self.local_qpack_encoder_stream, encoder_type, false),
    SendOnStream(self.local_qpack_decoder_stream, decoder_type, false),
  ])
}

///|
pub fn Http3Driver::cancel_request_stream(
  self : Http3Driver,
  stream_id : Int64,
) -> Result[Array[H3DriverAction], Http3Error] {
  let instruction = match self.connection.cancel_request_stream(stream_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match self.blocked_frames.get(stream_id) {
    Some(frames) =>
      for frame in frames {
        self.blocked_bytes -= h3_driver_blocked_frame_bytes(frame)
      }
    None => ()
  }
  self.blocked_frames.remove(stream_id)
  self.pending_fin.remove(stream_id)
  self.decoders.remove(stream_id)
  Ok([
    ResetStream(stream_id, H3RequestCancelled),
    SendOnStream(self.local_qpack_decoder_stream, instruction, false),
  ])
}

///|
pub fn Http3Driver::encode_headers(
  self : Http3Driver,
  stream_id : Int64,
  fields : Array[QpackField],
  fin? : Bool = false,
) -> Result[(Bytes, Bool), Http3Error] {
  let bytes = match self.connection.encode_headers_frame(stream_id, fields) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok((bytes, fin))
}

///|
pub fn Http3Driver::encode_data(
  self : Http3Driver,
  data : Bytes,
  fin? : Bool = false,
) -> Result[(Bytes, Bool), Http3Error] {
  let bytes = match self.connection.encode_data_frame(data) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok((bytes, fin))
}
