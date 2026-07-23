///|
pub(all) struct H2ClientConfig {
  limits : @types.Limits
  max_concurrent_streams : Int
  body_queue_capacity : Int
  read_size : Int
  read_timeout_ms : Int?
  write_timeout_ms : Int?
  close_callback : ((Error?) -> Unit)?
}

///|
pub fn H2ClientConfig::defaults() -> H2ClientConfig {
  {
    limits: @types.Limits::defaults(),
    max_concurrent_streams: 100,
    body_queue_capacity: 8,
    read_size: 8192,
    read_timeout_ms: None,
    write_timeout_ms: None,
    close_callback: None,
  }
}

///|
priv enum H2ClientBlockedFrame {
  BlockedData(Bytes, Bool)
  BlockedTrailers(@types.HeaderMap)
}

///|
priv struct H2ClientStream {
  id : Int
  head : @aqueue.Queue[@types.Response[Unit]]
  body : @body.BodyStream
  window_signal : @aqueue.Queue[Unit]
  mut response_started : Bool
  mut request_finished : Bool
  mut response_finished : Bool
  mut released : Bool
}

///|
priv struct H2ClientShared {
  config : H2ClientConfig
  runtime : @http2.H2Connection
  encoder : @http2.HpackContext
  decoder : @http2.HpackContext
  frames : @http2.FrameDecoder
  streams : Map[Int, H2ClientStream]
  blocked : Map[Int, H2ClientBlockedFrame]
  slots : @aqueue.Queue[Unit]
  blocked_signal : @aqueue.Queue[Unit]
  runtime_lock : @async.Mutex
  write_lock : @async.Mutex
  read : async (Int) -> Bytes?
  write : async (Bytes) -> Unit
  spawn : (async () -> Unit) -> Unit
  mut closed : Bool
  mut goaway : Bool
  mut close_notified : Bool
}

///|
pub struct H2Client {
  priv shared : H2ClientShared
}

///|
fn H2ClientShared::closed_error(_self : H2ClientShared) -> Error {
  @http2.H2ProtocolError::ConnectionError(
    Cancel,
    "HTTP/2 client connection is closed",
  )
}

///|
fn H2ClientShared::release_stream(
  self : H2ClientShared,
  stream : H2ClientStream,
) -> Unit {
  if stream.request_finished && stream.response_finished && !stream.released {
    stream.released = true
    self.streams.remove(stream.id)
    self.blocked.remove(stream.id)
    ignore(self.slots.try_put(()) catch { _ => false })
  }
}

///|
fn H2ClientShared::fail_stream(
  self : H2ClientShared,
  stream : H2ClientStream,
  error : Error,
) -> Unit {
  stream.request_finished = true
  stream.response_finished = true
  stream.body.fail(error)
  stream.head.close(error~)
  stream.window_signal.close(error~)
  self.release_stream(stream)
}

///|
fn H2ClientShared::close_with(self : H2ClientShared, error : Error?) -> Unit {
  if !self.closed {
    self.closed = true
    let failure = error.unwrap_or_else(fn() { self.closed_error() })
    let active : Array[H2ClientStream] = []
    for stream in self.streams.values() {
      active.push(stream)
    }
    for stream in active {
      self.fail_stream(stream, failure)
    }
    self.blocked_signal.close(error=failure)
    self.slots.close(error=failure)
  }
  if !self.close_notified {
    self.close_notified = true
    if self.config.close_callback is Some(callback) {
      callback(error)
    }
  }
}

///|
async fn H2ClientShared::write_bytes(
  self : H2ClientShared,
  bytes : Bytes,
) -> Unit {
  self.write_lock.acquire()
  defer self.write_lock.release()
  (self.write)(bytes)
}

///|
async fn H2ClientShared::release_capacity(
  self : H2ClientShared,
  stream_id : Int,
  amount : Int,
) -> Unit {
  if self.closed {
    return
  }
  self.runtime_lock.acquire()
  let updates = match self.runtime.release_capacity(stream_id, amount) {
    Ok(value) => value
    Err(error) => {
      self.runtime_lock.release()
      raise error
    }
  }
  self.runtime_lock.release()
  for update in updates {
    if update is SendWindowUpdate(id, value) {
      let encoded = match @http2.encode_window_update(id, value) {
        Ok(value) => value
        Err(error) => raise error
      }
      self.write_bytes(encoded)
    }
  }
  if !self.closed {
    self.blocked_signal.put(())
  }
}

///|
fn decode_client_response(
  stream_id : Int,
  fields : Array[@http2.HpackHeader],
) -> Result[(Int, @types.HeaderMap), @http2.H2ProtocolError] {
  let mut status = 0
  let mut saw_status = false
  let mut regular = false
  let headers = @types.HeaderMap::new()
  for field in fields {
    if field.name != field.name.to_lower() {
      return Err(
        StreamError(stream_id, ProtocolError, "uppercase response header"),
      )
    }
    if field.name.has_prefix(":") {
      if regular || field.name != ":status" || saw_status {
        return Err(
          StreamError(
            stream_id,
            ProtocolError,
            "invalid response pseudo-header",
          ),
        )
      }
      saw_status = true
      status = @string.parse_int(field.value) catch {
        _ =>
          return Err(
            StreamError(stream_id, ProtocolError, "invalid response status"),
          )
      }
    } else {
      regular = true
      if field.name == "connection" ||
        field.name == "upgrade" ||
        field.name == "keep-alive" ||
        field.name == "transfer-encoding" {
        return Err(
          StreamError(
            stream_id,
            ProtocolError,
            "connection-specific HTTP/2 response header",
          ),
        )
      }
      match headers.append_string(field.name, field.value) {
        Ok(_) => ()
        Err(_) =>
          return Err(
            StreamError(stream_id, ProtocolError, "invalid response header"),
          )
      }
    }
  }
  if !saw_status || status < 100 || status > 999 {
    return Err(StreamError(stream_id, ProtocolError, "missing response status"))
  }
  Ok((status, headers))
}

///|
fn decode_client_trailers(
  stream_id : Int,
  fields : Array[@http2.HpackHeader],
) -> Result[@types.HeaderMap, @http2.H2ProtocolError] {
  let headers = @types.HeaderMap::new()
  for field in fields {
    if field.name.has_prefix(":") {
      return Err(
        StreamError(
          stream_id,
          ProtocolError,
          "pseudo-header in response trailers",
        ),
      )
    }
    match headers.append_string(field.name, field.value) {
      Ok(_) => ()
      Err(_) =>
        return Err(
          StreamError(stream_id, ProtocolError, "invalid response trailers"),
        )
    }
  }
  Ok(headers)
}

///|
async fn H2ClientShared::reset_stream_with_error(
  self : H2ClientShared,
  stream_id : Int,
  code : @http2.H2ErrorCode,
  error : Error,
) -> Unit {
  if self.closed || self.streams.get(stream_id) is None {
    return
  }
  if self.streams.get(stream_id) is Some(stream) {
    self.fail_stream(stream, error)
  }
  self.runtime_lock.acquire()
  ignore(self.runtime.reset_stream(stream_id))
  self.runtime_lock.release()
  let encoded = match @http2.encode_rst_stream(stream_id, code) {
    Ok(value) => value
    Err(error) => raise error
  }
  self.write_bytes(encoded)
}

///|
async fn H2ClientShared::reset_stream(
  self : H2ClientShared,
  stream_id : Int,
  code : @http2.H2ErrorCode,
  message : String,
) -> Unit {
  self.reset_stream_with_error(
    stream_id,
    code,
    @http2.H2ProtocolError::StreamError(stream_id, code, message),
  )
}

///|
fn H2ClientShared::drain_blocked(self : H2ClientShared) -> Unit {
  for stream_id, blocked in self.blocked {
    guard self.streams.get(stream_id) is Some(stream) else {
      self.blocked.remove(stream_id)
      continue
    }
    let accepted = match blocked {
      BlockedData(data, _) =>
        stream.body.try_push(Data(data)) catch {
          error => {
            self.fail_stream(stream, error)
            false
          }
        }
      BlockedTrailers(trailers) =>
        stream.body.try_push(Trailers(trailers)) catch {
          error => {
            self.fail_stream(stream, error)
            false
          }
        }
    }
    if accepted {
      self.blocked.remove(stream_id)
      match blocked {
        BlockedData(_, true) | BlockedTrailers(_) => {
          stream.response_finished = true
          stream.body.finish()
          self.release_stream(stream)
        }
        BlockedData(_, false) => ()
      }
    }
  }
}

///|
async fn H2ClientShared::deliver_headers(
  self : H2ClientShared,
  stream_id : Int,
  fields : Array[@http2.HpackHeader],
  end_stream : Bool,
) -> Unit {
  guard self.streams.get(stream_id) is Some(stream) else { return }
  if !stream.response_started {
    let (status, headers) = match decode_client_response(stream_id, fields) {
      Ok(value) => value
      Err(error) => raise error
    }
    if status >= 100 && status < 200 {
      if end_stream {
        self.reset_stream(
          stream_id,
          ProtocolError,
          "informational response ended the stream",
        )
      }
      return
    }
    stream.response_started = true
    stream.head.put({ status, version: Http2, headers, body: () })
    if end_stream {
      stream.response_finished = true
      stream.body.finish()
      self.release_stream(stream)
    }
  } else {
    let trailers = match decode_client_trailers(stream_id, fields) {
      Ok(value) => value
      Err(error) => raise error
    }
    let accepted = stream.body.try_push(Trailers(trailers)) catch {
      error => {
        self.fail_stream(stream, error)
        false
      }
    }
    if accepted {
      stream.response_finished = true
      stream.body.finish()
      self.release_stream(stream)
    } else if self.blocked.get(stream_id) is Some(_) {
      self.reset_stream(
        stream_id,
        FlowControlError,
        "response body queue overflow",
      )
    } else {
      self.blocked.set(stream_id, BlockedTrailers(trailers))
    }
  }
}

///|
async fn H2ClientShared::deliver_data(
  self : H2ClientShared,
  stream_id : Int,
  data : Array[Byte],
  end_stream : Bool,
  flow_size : Int,
) -> Unit {
  guard self.streams.get(stream_id) is Some(stream) else { return }
  if flow_size > data.length() {
    self.release_capacity(stream_id, flow_size - data.length())
  }
  let bytes = Bytes::from_array(data)
  let accepted = stream.body.try_push(Data(bytes)) catch {
    error => {
      self.fail_stream(stream, error)
      false
    }
  }
  if accepted {
    if end_stream {
      stream.response_finished = true
      stream.body.finish()
      self.release_stream(stream)
    }
  } else if self.blocked.get(stream_id) is Some(_) {
    self.reset_stream(
      stream_id,
      FlowControlError,
      "response body queue overflow",
    )
  } else {
    self.blocked.set(stream_id, BlockedData(bytes, end_stream))
  }
}

///|
async fn H2ClientShared::finish_header_block(
  self : H2ClientShared,
  stream_id : Int,
  block : Array[Byte],
  end_stream : Bool,
) -> Unit {
  let fields = match self.decoder.decode(Bytes::from_array(block)) {
    Ok(value) => value
    Err(error) => raise error
  }
  self.deliver_headers(stream_id, fields, end_stream)
}

///|
async fn h2_client_reader_pump(shared : H2ClientShared) -> Unit {
  let header_block : Array[Byte] = []
  let mut header_stream = 0
  let mut header_end_stream = false
  for ;; {
    let bytes = match (shared.read)(shared.config.read_size) {
      Some(value) => value
      None => {
        if shared.streams.is_empty() {
          shared.close_with(None)
          return
        }
        let error = @http2.H2ProtocolError::ConnectionError(
          ProtocolError,
          "HTTP/2 peer closed connection",
        )
        shared.close_with(Some(error))
        raise error
      }
    }
    match shared.frames.feed(bytes) {
      Ok(_) => ()
      Err(error) => {
        shared.close_with(Some(error))
        raise error
      }
    }
    while true {
      let frame = match shared.frames.next() {
        Ok(Some(value)) => value
        Ok(None) => break
        Err(error) => {
          shared.close_with(Some(error))
          raise error
        }
      }
      shared.runtime_lock.acquire()
      let actions = match shared.runtime.receive(frame) {
        Ok(value) => value
        Err(error) => {
          shared.runtime_lock.release()
          shared.close_with(Some(error))
          raise error
        }
      }
      shared.runtime_lock.release()
      for action in actions {
        match action {
          SendSettingsAck =>
            shared.write_bytes(
              Bytes::from_array(@http2.encode_settings_frame([], true)),
            )
          SendPingAck(payload) => {
            let encoded = match @http2.encode_ping_ack(payload) {
              Ok(value) => value
              Err(error) => raise error
            }
            shared.write_bytes(encoded)
          }
          WindowAvailable(_, _) =>
            for stream in shared.streams.values() {
              ignore(stream.window_signal.try_put(()) catch { _ => false })
            }
          GoawayReceived(last_stream_id, code) => {
            shared.goaway = true
            let refused : Array[H2ClientStream] = []
            for id, stream in shared.streams {
              if id > last_stream_id {
                refused.push(stream)
              }
            }
            for stream in refused {
              shared.fail_stream(
                stream,
                @http2.H2ProtocolError::StreamError(
                  stream.id,
                  RefusedStream,
                  "stream was not processed before GOAWAY code \{code}",
                ),
              )
            }
          }
          HeadersStarted(id, end_stream) => {
            header_stream = id
            header_end_stream = end_stream
            header_block.clear()
            let fragment = match @http2.header_fragment(frame) {
              Ok(value) => value
              Err(error) => raise error
            }
            for byte in fragment {
              header_block.push(byte)
            }
            if (frame.header.flags & @http2.H2_FLAGS_END_HEADERS) != 0 {
              shared.finish_header_block(
                id,
                header_block.copy(),
                header_end_stream,
              )
              header_stream = 0
            }
          }
          HeadersContinued(id, end_headers) => {
            if id != header_stream {
              raise @http2.H2ProtocolError::ConnectionError(
                ProtocolError,
                "CONTINUATION stream changed",
              )
            }
            for byte in frame.payload {
              header_block.push(byte)
            }
            if end_headers {
              shared.finish_header_block(
                id,
                header_block.copy(),
                header_end_stream,
              )
              header_stream = 0
            }
          }
          DataReceived(id, data, end_stream, flow_size) =>
            shared.deliver_data(id, data, end_stream, flow_size)
          StreamResetReceived(id, code) =>
            if shared.streams.get(id) is Some(stream) {
              shared.fail_stream(
                stream,
                @http2.H2ProtocolError::StreamError(
                  id,
                  Cancel,
                  "peer reset stream with code \{code}",
                ),
              )
            }
          _ => ()
        }
      }
      shared.drain_blocked()
    }
  }
}

///|
async fn[B : @body.Body] send_h2_request_body(
  shared : H2ClientShared,
  stream : H2ClientStream,
  body : B,
) -> Unit {
  let mut sent_trailers = false
  try {
    while body.next_frame() is Some(frame) {
      match frame {
        Data(data) => {
          if sent_trailers {
            raise @http2.H2ProtocolError::StreamError(
              stream.id,
              ProtocolError,
              "request data follows trailers",
            )
          }
          let mut offset = 0
          while offset < data.length() {
            shared.runtime_lock.acquire()
            let capacity = match
              shared.runtime.reserve_send_capacity(
                stream.id,
                data.length() - offset,
              ) {
              Ok(value) => value
              Err(error) => {
                shared.runtime_lock.release()
                raise error
              }
            }
            shared.runtime_lock.release()
            if capacity == 0 {
              stream.window_signal.get()
              continue
            }
            let encoded = match
              @http2.encode_data_frames(
                stream.id,
                data[offset:offset + capacity].to_owned(),
                false,
              ) {
              Ok(value) => value
              Err(error) => raise error
            }
            shared.write_bytes(encoded)
            offset += capacity
          }
        }
        Trailers(trailers) => {
          if sent_trailers {
            raise @http2.H2ProtocolError::StreamError(
              stream.id,
              ProtocolError,
              "duplicate request trailers",
            )
          }
          sent_trailers = true
          shared.runtime_lock.acquire()
          let encoded = match
            @http2.encode_trailers(shared.encoder, stream.id, trailers) {
            Ok(value) => value
            Err(error) => {
              shared.runtime_lock.release()
              raise error
            }
          }
          shared.runtime_lock.release()
          shared.write_bytes(encoded)
        }
      }
    }
    if !sent_trailers {
      let encoded = match @http2.encode_data_frames(stream.id, b"", true) {
        Ok(value) => value
        Err(error) => raise error
      }
      shared.write_bytes(encoded)
    }
    shared.runtime_lock.acquire()
    let result = shared.runtime.finish_local_stream(stream.id)
    shared.runtime_lock.release()
    match result {
      Ok(_) => ()
      Err(error) => raise error
    }
    stream.request_finished = true
    shared.release_stream(stream)
  } catch {
    error => {
      shared.reset_stream(stream.id, Cancel, "request body producer failed")
      raise error
    }
  }
}

///|
pub async fn[B : @body.Body] H2Client::send(
  self : H2Client,
  request : @types.Request[B],
) -> @types.Response[@body.BodyStream] {
  if self.shared.closed {
    raise self.shared.closed_error()
  }
  if self.shared.goaway {
    raise @http2.H2ProtocolError::ConnectionError(
      RefusedStream,
      "cannot create stream after GOAWAY",
    )
  }
  self.shared.slots.get()
  let exact_zero = request.body.size_hint().exact_size() == Some(0)
  self.shared.runtime_lock.acquire()
  let stream_id = match
    self.shared.runtime.open_local_stream(end_stream=exact_zero) {
    Ok(value) => value
    Err(error) => {
      self.shared.runtime_lock.release()
      ignore(self.shared.slots.try_put(()) catch { _ => false })
      raise error
    }
  }
  let body = @body.BodyStream::new(
    capacity=self.shared.config.body_queue_capacity,
    on_data_consumed=async fn(amount) {
      self.shared.release_capacity(stream_id, amount) catch {
        error => {
          self.shared.reset_stream_with_error(stream_id, Cancel, error)
          raise error
        }
      }
    },
  )
  let stream : H2ClientStream = {
    id: stream_id,
    head: Queue(kind=Blocking(1)),
    body,
    window_signal: Queue(kind=Unbounded),
    response_started: false,
    request_finished: exact_zero,
    response_finished: false,
    released: false,
  }
  self.shared.streams.set(stream_id, stream)
  let encoded = match
    @http2.encode_request_headers(
      self.shared.encoder,
      stream_id,
      request,
      exact_zero,
    ) {
    Ok(value) => value
    Err(error) => {
      self.shared.runtime_lock.release()
      self.shared.fail_stream(stream, error)
      raise error
    }
  }
  self.shared.runtime_lock.release()
  self.shared.write_bytes(encoded)
  if !exact_zero {
    let producer = async fn() {
      send_h2_request_body(self.shared, stream, request.body)
    }
    (self.shared.spawn)(producer)
  }
  let response = stream.head.get()
  response.map_body(fn(_) { body })
}

///|
pub fn H2Client::close(self : H2Client) -> Unit {
  self.shared.close_with(None)
}

///|
pub async fn[R : @aio.Reader, W : @aio.Writer, X] with_h2_client_connection(
  reader : R,
  writer : W,
  run : async (H2Client) -> X,
  config? : H2ClientConfig = H2ClientConfig::defaults(),
) -> X {
  if config.max_concurrent_streams < 1 || config.body_queue_capacity < 1 {
    abort("HTTP/2 client queue and concurrency limits must be positive")
  }
  @async.with_task_group(async fn(group) {
    let slots : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
    for _ in 0..<config.max_concurrent_streams {
      slots.put(())
    }
    let shared : H2ClientShared = {
      config,
      runtime: @http2.H2Connection::new(Client),
      encoder: @http2.HpackContext::new(
        max_header_list_size=config.limits.max_header_bytes,
      ),
      decoder: @http2.HpackContext::new(
        max_header_list_size=config.limits.max_header_bytes,
      ),
      frames: @http2.FrameDecoder::new(
        max_buffer_size=config.limits.max_buffer_bytes,
      ),
      streams: Map([]),
      blocked: Map([]),
      slots,
      blocked_signal: Queue(kind=Unbounded),
      runtime_lock: Mutex(),
      write_lock: Mutex(),
      read: async fn(max_len) {
        read_some_with_timeout(reader, max_len, config.read_timeout_ms)
      },
      write: async fn(bytes) {
        write_with_timeout(writer, bytes, config.write_timeout_ms)
      },
      spawn: fn(task) { group.spawn_bg(task, allow_failure=true) },
      closed: false,
      goaway: false,
      close_notified: false,
    }
    let client : H2Client = { shared, }
    group.add_defer(fn() { shared.close_with(None) })
    shared.write_bytes(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
    let receive_window = (config.body_queue_capacity + 1) *
      @http2.H2_DEFAULT_MAX_FRAME_SIZE
    shared.write_bytes(
      Bytes::from_array(
        @http2.encode_settings_frame([{ id: 4, value: receive_window }], false),
      ),
    )
    match shared.runtime.set_local_initial_window(receive_window) {
      Ok(_) => ()
      Err(error) => raise error
    }
    if receive_window > 65535 {
      let increment = receive_window - 65535
      match shared.runtime.increase_connection_receive_window(increment) {
        Ok(_) => ()
        Err(error) => raise error
      }
      shared.write_bytes(@http2.encode_window_update(0, increment).unwrap())
    }
    group.spawn_bg(async fn() { h2_client_reader_pump(shared) }, no_wait=true)
    group.spawn_bg(
      async fn() {
        while true {
          shared.blocked_signal.get() catch {
            _ => return
          }
          shared.drain_blocked()
        }
      },
      no_wait=true,
      allow_failure=true,
    )
    run(client)
  })
}
