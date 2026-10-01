///|
pub(all) enum H3Role {
  H3Client
  H3Server
} derive(Eq, Debug)

///|
pub(all) enum H3Action {
  H3PeerSettingsReceived(H3Settings)
  H3SendQpackEncoderInstruction(Bytes)
  H3SendQpackDecoderInstruction(Bytes)
  H3HeadersReceived(Int64, Array[QpackField], Bool, Bool)
  H3DataReceived(Int64, Bytes)
  H3PushPromiseReceived(Int64, Int64, Array[QpackField])
  H3CancelPushReceived(Int64)
  H3MaxPushIdReceived(Int64)
  H3GoawayReceived(Int64)
  H3UnknownFrameIgnored(Int64)
} derive(Eq, Debug)

///|
pub struct Http3Connection {
  role : H3Role
  limits : @types.Limits
  qpack_limits : QpackLimits
  decoder : QpackDecoder
  encoder : QpackEncoder
  priv streams : Map[Int64, H3RequestStreamState]
  mut remote_control_stream : Int64?
  mut remote_qpack_encoder_stream : Int64?
  mut remote_qpack_decoder_stream : Int64?
  mut control_received_frame : Bool
  mut settings_received : Bool
  mut peer_settings : H3Settings
  mut local_enable_connect_protocol : Bool
  mut goaway_id : Int64?
  mut max_push_id : Int64?
  mut next_request_stream_id : Int64
  mut failure : Http3Error?
}

///|
pub fn Http3Connection::new(
  role : H3Role,
  limits? : @types.Limits = @types.Limits::defaults(),
  qpack_limits? : QpackLimits = QpackLimits::defaults(),
) -> Result[Http3Connection, Http3Error] {
  match limits.validate() {
    Ok(_) => ()
    Err(_) => return Err(Http3LimitExceeded("shared HTTP limits", 0))
  }
  match qpack_limits.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if qpack_limits.max_table_capacity > limits.max_dynamic_table_bytes ||
    qpack_limits.max_field_count > limits.max_header_count ||
    qpack_limits.max_decoded_field_section_bytes > limits.max_header_bytes ||
    qpack_limits.max_encoded_field_section_bytes > limits.max_header_bytes ||
    qpack_limits.max_instruction_buffer_bytes > limits.max_buffer_bytes {
    return Err(
      Http3LimitExceeded(
        "QPACK limits exceed shared HTTP limits",
        limits.max_buffer_bytes,
      ),
    )
  }
  let decoder = match QpackDecoder::new(limits=qpack_limits) {
    Ok(result) => result
    Err(error) => return Err(error)
  }
  let encoder = match QpackEncoder::new(limits=qpack_limits) {
    Ok(result) => result
    Err(error) => return Err(error)
  }
  Ok({
    role,
    limits,
    qpack_limits,
    decoder,
    encoder,
    streams: Map([]),
    remote_control_stream: None,
    remote_qpack_encoder_stream: None,
    remote_qpack_decoder_stream: None,
    control_received_frame: false,
    settings_received: false,
    peer_settings: H3Settings::defaults(),
    local_enable_connect_protocol: false,
    goaway_id: None,
    max_push_id: None,
    next_request_stream_id: 0L,
    failure: None,
  })
}

///|
pub fn Http3Connection::qpack_decoder(self : Http3Connection) -> QpackDecoder {
  self.decoder
}

///|
pub fn Http3Connection::qpack_encoder(self : Http3Connection) -> QpackEncoder {
  self.encoder
}

///|
pub fn Http3Connection::open_request_stream(
  self : Http3Connection,
  request_method? : String? = None,
) -> Result[Int64, Http3Error] {
  if self.role != H3Client {
    return Err(
      Http3ConnectionError(
        H3StreamCreationError,
        "servers cannot initiate request streams",
      ),
    )
  }
  if self.goaway_id is Some(limit) && self.next_request_stream_id >= limit {
    return Err(
      Http3StreamError(
        self.next_request_stream_id,
        H3RequestRejected,
        "request rejected by GOAWAY",
      ),
    )
  }
  if self.streams.length() >= self.limits.max_streams {
    return Err(
      Http3LimitExceeded("HTTP/3 request streams", self.limits.max_streams),
    )
  }
  if self.next_request_stream_id > @quic.QUIC_MAX_VARINT - 4L {
    return Err(
      Http3ConnectionError(
        H3StreamCreationError,
        "request stream IDs are exhausted",
      ),
    )
  }
  let id = self.next_request_stream_id
  self.next_request_stream_id += 4L
  self.streams.set(
    id,
    H3RequestStreamState::new(id, H3IncomingResponse(request_method)),
  )
  Ok(id)
}

///|
pub fn Http3Connection::accept_request_stream(
  self : Http3Connection,
  stream_id : Int64,
) -> Result[Unit, Http3Error] {
  if self.role != H3Server || stream_id < 0L || (stream_id & 3L) != 0L {
    return Err(
      Http3ConnectionError(
        H3StreamCreationError,
        "invalid incoming request stream",
      ),
    )
  }
  if self.streams.get(stream_id) is Some(_) {
    return Err(
      Http3ConnectionError(H3StreamCreationError, "duplicate request stream"),
    )
  }
  if self.streams.length() >= self.limits.max_streams {
    return Err(
      Http3LimitExceeded("HTTP/3 request streams", self.limits.max_streams),
    )
  }
  self.streams.set(
    stream_id,
    H3RequestStreamState::new(stream_id, H3IncomingRequest),
  )
  Ok(())
}

///|
pub fn Http3Connection::receive_request_frame(
  self : Http3Connection,
  stream_id : Int64,
  frame : Http3Frame,
) -> Result[Array[H3Action], Http3Error] {
  if !self.settings_received {
    return Err(
      Http3ConnectionError(
        H3MissingSettings,
        "request stream data arrived before SETTINGS",
      ),
    )
  }
  let stream = match self.streams.get(stream_id) {
    Some(result) => result
    None =>
      return Err(
        Http3StreamError(
          stream_id,
          H3RequestIncomplete,
          "unknown request stream",
        ),
      )
  }
  let actions : Array[H3Action] = []
  match frame {
    H3Headers(section) => {
      let decoded = match
        self.decoder.decode_field_section(stream_id, section) {
        Ok(result) => result
        Err(error) => return Err(error)
      }
      match decoded {
        QpackBlocked(_) => ()
        QpackDecoded(fields, acknowledgment_required) => {
          let (trailers, informational) = match
            stream.receive_headers(fields, self.local_enable_connect_protocol) {
            Ok(result) => result
            Err(error) => return Err(error)
          }
          actions.push(
            H3HeadersReceived(stream_id, fields, trailers, informational),
          )
          if acknowledgment_required {
            let instruction = match qpack_section_acknowledgment(stream_id) {
              Ok(result) => result
              Err(error) => return Err(error)
            }
            actions.push(H3SendQpackDecoderInstruction(instruction))
          }
        }
      }
    }
    H3Data(data) =>
      match stream.receive_data(data, self.limits.max_body_bytes) {
        Ok(_) => actions.push(H3DataReceived(stream_id, data))
        Err(error) => return Err(error)
      }
    H3PushPromise(push_id, section) => {
      if self.role != H3Client {
        return Err(
          Http3ConnectionError(H3FrameUnexpected, "client sent PUSH_PROMISE"),
        )
      }
      let decoded = match
        self.decoder.decode_field_section(stream_id, section) {
        Ok(result) => result
        Err(error) => return Err(error)
      }
      match decoded {
        QpackBlocked(_) => ()
        QpackDecoded(fields, acknowledgment_required) => {
          match
            validate_http3_field_section(stream_id, fields, H3PushPromiseFields) {
            Ok(_) => ()
            Err(error) => return Err(error)
          }
          actions.push(H3PushPromiseReceived(stream_id, push_id, fields))
          if acknowledgment_required {
            let instruction = match qpack_section_acknowledgment(stream_id) {
              Ok(result) => result
              Err(error) => return Err(error)
            }
            actions.push(H3SendQpackDecoderInstruction(instruction))
          }
        }
      }
    }
    H3Unknown(typ, _) => actions.push(H3UnknownFrameIgnored(typ))
    _ =>
      return Err(
        Http3StreamError(
          stream_id,
          H3FrameUnexpected,
          "frame type is not permitted on an HTTP/3 request stream",
        ),
      )
  }
  Ok(actions)
}

///|
pub fn Http3Connection::finish_request_stream(
  self : Http3Connection,
  stream_id : Int64,
) -> Result[Unit, Http3Error] {
  let stream = match self.streams.get(stream_id) {
    Some(result) => result
    None =>
      return Err(
        Http3StreamError(
          stream_id,
          H3RequestIncomplete,
          "unknown request stream",
        ),
      )
  }
  match stream.finish() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  self.streams.remove(stream_id)
  Ok(())
}

///|
pub fn Http3Connection::cancel_request_stream(
  self : Http3Connection,
  stream_id : Int64,
) -> Result[Bytes, Http3Error] {
  match self.streams.get(stream_id) {
    Some(stream) => stream.cancel()
    None => ()
  }
  self.decoder.cancel_stream(stream_id)
  self.streams.remove(stream_id)
  qpack_stream_cancellation(stream_id)
}

///|
pub fn Http3Connection::stream_phase(
  self : Http3Connection,
  stream_id : Int64,
) -> H3MessagePhase? {
  match self.streams.get(stream_id) {
    Some(stream) => Some(stream.phase)
    None => None
  }
}

///|
pub fn Http3Connection::feed_qpack_encoder_stream(
  self : Http3Connection,
  bytes : BytesView,
) -> Result[Array[Int64], Http3Error] {
  match self.decoder.feed_encoder_stream(bytes) {
    Ok(_) => Ok(self.decoder.ready_blocked_streams())
    Err(error) => Err(error)
  }
}

///|
pub fn Http3Connection::feed_qpack_decoder_stream(
  self : Http3Connection,
  bytes : BytesView,
) -> Result[Unit, Http3Error] {
  self.encoder.feed_decoder_stream(bytes)
}

///|
pub fn Http3Connection::encode_headers_frame(
  self : Http3Connection,
  stream_id : Int64,
  fields : Array[QpackField],
) -> Result[Bytes, Http3Error] {
  // This low-level encoder also carries responses and trailers. CONNECT request
  // fields need the connection's negotiation context before any QPACK state is
  // updated; the standalone field-section codec cannot supply that context.
  if fields.any(fn(field) {
      field.name == ":protocol" ||
      (field.name == ":method" && field.value == b"CONNECT")
    }) {
    let kind = if self.role == H3Client {
      H3RequestFields
    } else {
      H3ResponseFields
    }
    match
      validate_http3_field_section(
        stream_id,
        fields,
        kind,
        enable_connect_protocol=self.peer_settings.enable_connect_protocol,
      ) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  let section = match self.encoder.encode_field_section(stream_id, fields) {
    Ok(result) => result
    Err(error) => return Err(error)
  }
  encode_http3_frame(H3Headers(section))
}

///|
pub fn Http3Connection::encode_data_frame(
  self : Http3Connection,
  data : Bytes,
) -> Result[Bytes, Http3Error] {
  if data.length() > self.limits.max_body_bytes {
    return Err(Http3LimitExceeded("HTTP/3 DATA", self.limits.max_body_bytes))
  }
  encode_http3_frame(H3Data(data))
}
