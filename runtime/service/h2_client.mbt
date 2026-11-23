///|
#warnings("-unnecessary_annotation")
pub(all) struct H2ClientConfig {
  limits : @types.Limits
  max_concurrent_streams : Int32
  body_queue_capacity : Int32
  h2_receive_window_bytes : Int32
  read_size : Int32
  read_timeout_ms : Int32?
  write_timeout_ms : Int32?
  close_callback : ((Error?) -> Unit)?
}

///|
pub fn H2ClientConfig::defaults() -> H2ClientConfig {
  {
    limits: @types.Limits::defaults(),
    max_concurrent_streams: 100,
    body_queue_capacity: 8,
    h2_receive_window_bytes: 65535,
    read_size: 8192,
    read_timeout_ms: Some(30000),
    write_timeout_ms: Some(30000),
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
  id : Int32
  head : @aqueue.Queue[@types.Response[Unit]]
  body : @body.BodyStream
  credit : H2ReceiveCredit
  window_signal : @cond_var.Cond
  request_method : @types.Method
  mut response_body_bytes : Int32
  mut expected_response_bytes : Int32?
  mut response_body_allowed : Bool
  mut response_started : Bool
  mut request_finished : Bool
  mut response_ended : Bool
  mut response_finished : Bool
  mut released : Bool
  mut upload : @async.Task[Unit]?
}

///|
priv struct H2ClientShared {
  config : H2ClientConfig
  runtime : @http2.H2Connection
  encoder : @http2.HpackContext
  decoder : @http2.HpackContext
  frames : @http2.FrameDecoder
  streams : Map[Int32, H2ClientStream]
  // DATA in this backlog has already consumed HTTP/2 receive credit. Credit
  // is restored only after BodyStream consumption, keeping it byte-bounded.
  blocked : Map[Int32, @deque.Deque[H2ClientBlockedFrame]]
  state_changed : () -> Unit
  mut received_settings : Bool
  admission : @cond_var.Cond
  blocked_signal : @aqueue.Queue[Unit]
  runtime_lock : @async.Mutex
  write_lock : @async.Mutex
  read : async (Int32) -> Bytes?
  write : async (Bytes) -> Unit
  spawn : (async () -> Unit) -> @async.Task[Unit]
  mut failure : Error?
  mut draining : Bool
  mut close_notified : Bool
  mut discarded_capacity : Int32
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
    self.admission.signal()
    if self.streams.is_empty() {
      (self.state_changed)()
    }
  }
}

///|
fn H2ClientShared::fail_stream(
  self : H2ClientShared,
  stream : H2ClientStream,
  error : Error,
) -> Unit {
  stream.request_finished = true
  stream.response_ended = true
  stream.response_finished = true
  self.discard_capacity(stream.credit.retire())
  if stream.upload is Some(task) {
    task.cancel()
  }
  stream.body.fail(error)
  stream.head.close(error~)
  stream.window_signal.broadcast()
  self.release_stream(stream)
}

///|
fn H2ClientShared::discard_capacity(
  self : H2ClientShared,
  amount : Int32,
) -> Unit {
  if amount > 0 && self.failure is None {
    self.discarded_capacity += amount
    ignore(self.blocked_signal.try_put(()) catch { _ => false })
  }
}

///|
async fn H2ClientShared::write_window_updates(
  self : H2ClientShared,
  updates : Array[@http2.H2Action],
) -> Unit {
  self.write_lock.acquire()
  defer self.write_lock.release()
  // Completed bodies remain readable after the peer closes. Their queued
  // credit no longer needs a wire update once the connection is closed.
  if self.failure is Some(_) {
    return
  }
  for update in updates {
    if update is SendWindowUpdate(id, value) {
      let encoded = match @http2.encode_window_update(id, value) {
        Ok(value) => value
        Err(error) => raise error
      }
      self.write_locked(encoded)
    }
  }
}

///|
async fn H2ClientShared::release_discarded_capacity(
  self : H2ClientShared,
) -> Unit {
  if self.failure is Some(_) {
    return
  }
  let updates = {
    self.runtime_lock.acquire()
    defer self.runtime_lock.release()
    let updates = match self.runtime.release_discarded_capacity() {
      Ok(value) => value
      Err(error) => raise error
    }
    let amount = self.discarded_capacity
    if amount > 0 {
      let update = match self.runtime.release_connection_capacity(amount) {
        Ok(value) => value
        Err(error) => raise error
      }
      self.discarded_capacity = 0
      updates.push(update)
    }
    updates
  }
  self.write_window_updates(updates)
}

///|
fn H2ClientShared::close_with(self : H2ClientShared, error : Error?) -> Unit {
  if self.failure is None {
    let failure = error.unwrap_or_else(fn() { self.closed_error() })
    self.failure = Some(failure)
    let active : Array[H2ClientStream] = []
    for stream in self.streams.values() {
      active.push(stream)
    }
    for stream in active {
      self.fail_stream(stream, failure)
    }
    (self.state_changed)()
    self.blocked_signal.close(error=failure)
    self.admission.broadcast()
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
  self.write_locked(bytes)
}

///|
/// An interrupted partial frame makes the entire connection unusable. All
/// writers check this under the shared lock before emitting subsequent bytes.
async fn H2ClientShared::write_locked(
  self : H2ClientShared,
  bytes : Bytes,
) -> Unit {
  if self.failure is Some(_) {
    raise self.closed_error()
  }
  errdefer self.close_with(
    Some(
      @http2.H2ProtocolError::ConnectionError(
        Cancel,
        "HTTP/2 frame write interrupted",
      ),
    ),
  )
  (self.write)(bytes)
}

///|
/// HPACK mutations and the resulting bytes share the wire's serialization
/// point; parallel streams cannot encode in a different order from writes.
async fn H2ClientShared::write_headers(
  self : H2ClientShared,
  encode : () -> Result[Bytes, @http2.H2ProtocolError],
) -> Unit {
  self.write_lock.acquire()
  defer self.write_lock.release()
  let bytes = match encode() {
    Ok(value) => value
    Err(error) => raise error
  }
  self.write_locked(bytes)
}

///|
async fn H2ClientShared::release_capacity(
  self : H2ClientShared,
  stream_id : Int32,
  amount : Int32,
) -> Unit {
  if self.failure is Some(_) {
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
  self.write_window_updates(updates)
  if self.failure is None {
    self.blocked_signal.put(())
  }
}

///|
/// Claim body-consumption credit only after the write lock is held. A body
/// cancellation can retire the credit while this callback waits for another
/// writer; claiming it before that wait would lose the peer-visible window.
async fn H2ClientShared::release_consumed_capacity(
  self : H2ClientShared,
  stream_id : Int32,
  credit : H2ReceiveCredit,
  amount : Int32,
) -> Unit {
  if self.failure is Some(_) || amount <= 0 {
    return
  }
  self.write_lock.acquire()
  defer self.write_lock.release()
  if self.failure is Some(_) {
    return
  }
  self.runtime_lock.acquire()
  defer self.runtime_lock.release()
  let claimed = credit.consume(amount)
  if claimed == 0 {
    return
  }
  let updates = match self.runtime.release_capacity(stream_id, claimed) {
    Ok(value) => value
    Err(error) => raise error
  }
  for update in updates {
    if update is SendWindowUpdate(id, value) {
      let encoded = match @http2.encode_window_update(id, value) {
        Ok(value) => value
        Err(error) => raise error
      }
      self.write_locked(encoded)
    }
  }
  if self.failure is None {
    self.blocked_signal.put(())
  }
}

///|
fn decode_client_response(
  stream_id : Int32,
  fields : Array[@http2.HpackHeader],
) -> Result[(Int32, @types.HeaderMap), @http2.H2ProtocolError] {
  let mut status = 0
  let mut saw_status = false
  let mut regular = false
  let headers = @types.HeaderMap::new()
  for field in fields {
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
      let value = match h2_field_text(field.value) {
        Some(value) => value
        None =>
          return Err(
            StreamError(stream_id, ProtocolError, "invalid response status"),
          )
      }
      status = @string.parse_int(value) catch {
        _ =>
          return Err(
            StreamError(stream_id, ProtocolError, "invalid response status"),
          )
      }
    } else {
      regular = true
      if !@http_fields.Response.allows(field.name, field.value) {
        return Err(
          StreamError(
            stream_id,
            ProtocolError,
            "connection-specific HTTP/2 response header",
          ),
        )
      }
      if !append_regular_header(headers, field.name, field.value) {
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
  stream_id : Int32,
  fields : Array[@http2.HpackHeader],
) -> Result[@types.HeaderMap, @http2.H2ProtocolError] {
  let headers = @types.HeaderMap::new()
  for field in fields {
    if field.name.has_prefix(":") ||
      !@http_fields.Trailers.allows(field.name, field.value) {
      return Err(
        StreamError(
          stream_id,
          ProtocolError,
          "forbidden HTTP/2 response trailer",
        ),
      )
    }
    if !append_regular_header(headers, field.name, field.value) {
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
  stream_id : Int32,
  code : @http2.H2ErrorCode,
  error : Error,
) -> Unit {
  if self.failure is Some(_) {
    return
  }
  if self.streams.get(stream_id) is Some(stream) {
    self.fail_stream(stream, error)
  }
  self.runtime_lock.acquire()
  ignore(self.runtime.reset_stream(stream_id))
  self.runtime_lock.release()
  self.admission.signal()
  let encoded = match @http2.encode_rst_stream(stream_id, code) {
    Ok(value) => value
    Err(error) => raise error
  }
  self.write_bytes(encoded)
}

///|
async fn H2ClientShared::reset_stream(
  self : H2ClientShared,
  stream_id : Int32,
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
/// Retire the stream immediately. A connection task owns the wire reset so a
/// cancelled producer or consumer never has to wait for the writer lock.
fn H2ClientShared::cancel_stream(
  self : H2ClientShared,
  stream_id : Int32,
  error : Error,
) -> Unit {
  guard self.streams.get(stream_id) is Some(stream) else { return }
  self.fail_stream(stream, error)
  ignore(
    (self.spawn)(async fn() {
      self.reset_stream_with_error(stream_id, Cancel, error) catch {
        failure => self.close_with(Some(failure))
      }
    }),
  )
}

///|
fn H2ClientShared::drain_blocked(self : H2ClientShared) -> Unit {
  for stream_id, queue in self.blocked {
    guard self.streams.get(stream_id) is Some(stream) else {
      self.blocked.remove(stream_id)
      continue
    }
    while queue.front() is Some(blocked) {
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
        ignore(queue.pop_front())
        match blocked {
          BlockedData(_, true) | BlockedTrailers(_) => {
            stream.response_finished = true
            stream.body.finish()
            self.release_stream(stream)
          }
          BlockedData(_, false) => ()
        }
      } else {
        break
      }
    }
    if queue.is_empty() {
      self.blocked.remove(stream_id)
    }
  }
}

///|
fn H2ClientShared::queue_blocked(
  self : H2ClientShared,
  stream_id : Int32,
  frame : H2ClientBlockedFrame,
) -> Unit {
  let queue = self.blocked.get_or_init(stream_id, fn() { Deque([]) })
  queue.push_back(frame)
}

///|
async fn H2ClientShared::deliver_headers(
  self : H2ClientShared,
  stream_id : Int32,
  fields : Array[@http2.HpackHeader],
  end_stream : Bool,
) -> Unit {
  guard self.streams.get(stream_id) is Some(stream) else { return }
  // A trailers block (and any other END_STREAM response frame) terminates
  // the peer's response immediately.  Keep the stream entry alive while a
  // bounded body queue drains, but reject every later HEADERS/DATA frame
  // instead of appending it behind the terminal block.
  if stream.response_ended {
    self.reset_stream(
      stream_id,
      ProtocolError,
      "response frame follows stream end",
    )
    return
  }
  if !stream.response_started {
    let (status, headers) = match decode_client_response(stream_id, fields) {
      Ok(value) => value
      Err(error) => raise error
    }
    if status >= 100 && status < 200 {
      if status == 101 ||
        end_stream ||
        !headers.get_all_string("content-length").is_empty() {
        self.reset_stream(
          stream_id,
          ProtocolError,
          "informational response ended the stream",
        )
      }
      return
    }
    let content_length = match headers.content_length() {
      Ok(value) => value
      Err(_) => {
        self.reset_stream(
          stream_id,
          ProtocolError,
          "invalid response content-length",
        )
        return
      }
    }
    let tunnel = stream.request_method == Connect &&
      status >= 200 &&
      status < 300
    if (status == 204 || tunnel) && content_length is Some(_) {
      self.reset_stream(
        stream_id,
        ProtocolError,
        "content-length is forbidden for this response",
      )
      return
    }
    stream.response_body_allowed = stream.request_method != Head &&
      status != 204 &&
      status != 304
    stream.expected_response_bytes = if stream.response_body_allowed && !tunnel {
      content_length
    } else {
      None
    }
    if stream.expected_response_bytes is Some(length) &&
      length > self.config.limits.max_body_bytes {
      self.reset_stream(
        stream_id,
        EnhanceYourCalm,
        "response body exceeds configured limit",
      )
      return
    }
    if end_stream &&
      stream.expected_response_bytes is Some(length) &&
      length != 0 {
      self.reset_stream(
        stream_id,
        ProtocolError,
        "response ended before content-length",
      )
      return
    }
    stream.response_started = true
    stream.head.put({ status, version: Http2, headers, body: (), })
    if end_stream {
      stream.response_ended = true
      stream.response_finished = true
      stream.body.finish()
      self.release_stream(stream)
    }
  } else {
    if !end_stream {
      self.reset_stream(
        stream_id,
        ProtocolError,
        "response trailers must end the stream",
      )
      return
    }
    match
      stream.accept_response_data(0, true, self.config.limits.max_body_bytes) {
      Ok(_) => ()
      Err(StreamError(_, code, message)) => {
        self.reset_stream(stream_id, code, message)
        return
      }
      Err(error) => raise error
    }
    let trailers = match decode_client_trailers(stream_id, fields) {
      Ok(value) => value
      Err(error) => raise error
    }
    // Mark terminal state before attempting to enqueue trailers.  The body
    // queue may be full; the stream must still reject later frames while the
    // queued trailers await consumption.
    stream.response_ended = true
    if self.blocked.get(stream_id) is Some(_) {
      self.queue_blocked(stream_id, BlockedTrailers(trailers))
      return
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
    } else {
      self.queue_blocked(stream_id, BlockedTrailers(trailers))
    }
  }
}

///|
async fn H2ClientShared::deliver_data(
  self : H2ClientShared,
  stream_id : Int32,
  data : Array[Byte],
  end_stream : Bool,
  flow_size : Int32,
) -> Unit {
  guard self.streams.get(stream_id) is Some(stream) else {
    self.discard_capacity(flow_size)
    return
  }
  stream.credit.outstanding += flow_size
  if stream.response_ended {
    self.reset_stream(
      stream_id,
      ProtocolError,
      "response data follows stream end",
    )
    return
  }
  match
    stream.accept_response_data(
      data.length(),
      end_stream,
      self.config.limits.max_body_bytes,
    ) {
    Ok(_) => ()
    Err(StreamError(_, code, message)) => {
      self.reset_stream(stream_id, code, message)
      return
    }
    Err(error) => raise error
  }
  if flow_size > data.length() {
    let amount = stream.credit.consume(flow_size - data.length())
    self.release_capacity(stream_id, amount)
  }
  if data.is_empty() && !end_stream {
    return
  }
  if end_stream {
    // Preserve the terminal state even when the bounded body queue is full;
    // drain_blocked() will finish the body after the queued DATA is consumed.
    stream.response_ended = true
  }
  let bytes = Bytes::from_array(data)
  if self.blocked.get(stream_id) is Some(_) {
    self.queue_blocked(stream_id, BlockedData(bytes, end_stream))
    return
  }
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
  } else {
    self.queue_blocked(stream_id, BlockedData(bytes, end_stream))
  }
}

///|
async fn H2ClientShared::finish_header_block(
  self : H2ClientShared,
  stream_id : Int32,
  block : Array[Byte],
  end_stream : Bool,
  discarded : @http2.H2ErrorCode?,
) -> Unit {
  let fields = match self.decoder.decode(Bytes::from_array(block)) {
    Ok(value) => value
    Err(error) => raise error
  }
  if discarded is Some(code) {
    self.reset_stream(stream_id, code, "discarded header block")
    return
  }
  self.deliver_headers(stream_id, fields, end_stream)
}

///|
async fn h2_client_reader_pump(shared : H2ClientShared) -> Unit {
  let header_block : Array[Byte] = []
  let mut header_stream = 0
  let mut header_end_stream = false
  let mut discarded_header_code : @http2.H2ErrorCode? = None
  for ;; {
    let bytes = match (shared.read)(shared.config.read_size) {
      Some(value) => value
      None => {
        if !shared.received_settings {
          raise @http2.H2ProtocolError::ConnectionError(
            ProtocolError,
            "HTTP/2 peer closed before initial SETTINGS",
          )
        }
        if shared.streams.is_empty() {
          shared.close_with(None)
          return
        }
        let error = @http2.H2ProtocolError::ConnectionError(
          ProtocolError,
          "HTTP/2 peer closed connection",
        )
        raise error
      }
    }
    match shared.frames.feed(bytes) {
      Ok(_) => ()
      Err(error) => raise error
    }
    while true {
      let frame = match shared.frames.next() {
        Ok(Some(value)) => value
        Ok(None) => break
        Err(error) => raise error
      }
      if !shared.received_settings {
        require_initial_h2_settings(frame)
      }
      shared.runtime_lock.acquire()
      let actions = match shared.runtime.receive(frame) {
        Ok(value) => value
        Err(StreamError(stream_id, code, message)) => {
          shared.runtime_lock.release()
          shared.reset_stream(stream_id, code, "peer stream error: " + message)
          shared.release_discarded_capacity()
          continue
        }
        Err(ConnectionError(code, message)) => {
          let error = @http2.H2ProtocolError::ConnectionError(code, message)
          shared.runtime_lock.release()
          raise error
        }
      }
      shared.runtime_lock.release()
      for action in actions {
        match action {
          PeerHeaderTableSize(size) => {
            shared.write_lock.acquire()
            shared.encoder.set_encoder_table_size(size)
            shared.write_lock.release()
          }
          SendSettingsAck => {
            shared.received_settings = true
            shared.admission.broadcast()
            shared.write_bytes(
              Bytes::from_array(@http2.encode_settings_frame([], true)),
            )
          }
          SendPingAck(payload) => {
            let encoded = match @http2.encode_ping_ack(payload) {
              Ok(value) => value
              Err(error) => raise error
            }
            shared.write_bytes(encoded)
          }
          WindowAvailable(_, _) =>
            for stream in shared.streams.values() {
              stream.window_signal.broadcast()
            }
          GoawayReceived(last_stream_id, code) => {
            shared.draining = true
            (shared.state_changed)()
            shared.admission.broadcast()
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
            // Wire capacity can return before the application drains a body.
            if end_stream {
              shared.admission.signal()
            }
            discarded_header_code = None
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
                discarded_header_code,
              ) catch {
                @http2.H2ProtocolError::StreamError(error_id, code, message) =>
                  shared.reset_stream(error_id, code, message)
                error => raise error
              }
              header_stream = 0
            }
          }
          HeadersDiscarded(id, end_headers, code) => {
            header_stream = id
            header_end_stream = false
            discarded_header_code = Some(code)
            header_block.clear()
            let fragment = match @http2.header_fragment(frame) {
              Ok(value) => value
              Err(error) => raise error
            }
            for byte in fragment {
              header_block.push(byte)
            }
            if end_headers {
              shared.finish_header_block(
                id,
                header_block.copy(),
                false,
                discarded_header_code,
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
                discarded_header_code,
              ) catch {
                @http2.H2ProtocolError::StreamError(error_id, code, message) =>
                  shared.reset_stream(error_id, code, message)
                error => raise error
              }
              header_stream = 0
            }
          }
          DataReceived(id, data, end_stream, flow_size) => {
            if end_stream {
              shared.admission.signal()
            }
            shared.deliver_data(id, data, end_stream, flow_size)
          }
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
      shared.release_discarded_capacity()
      shared.drain_blocked()
    }
  }
}

///|
async fn[B : @body.Body] send_h2_request_body(
  shared : H2ClientShared,
  stream : H2ClientStream,
  body : B,
  expected : Int32?,
) -> Unit {
  errdefer body.cancel(@body.BodyError::Cancelled)
  errdefer shared.cancel_stream(
    stream.id,
    @http2.H2ProtocolError::StreamError(
      stream.id,
      Cancel,
      "request body producer failed",
    ),
  )
  write_h2_body(
    stream.id,
    body,
    expected,
    false,
    async fn(requested) {
      for ;; {
        if stream.request_finished || shared.failure is Some(_) {
          raise shared.closed_error()
        }
        shared.runtime_lock.acquire()
        let result = shared.runtime.reserve_send_capacity(stream.id, requested)
        shared.runtime_lock.release()
        let capacity = result.unwrap_or_error()
        if capacity > 0 {
          return capacity
        }
        stream.window_signal.wait()
      }
    },
    bytes => shared.write_bytes(bytes),
    trailers => {
      shared.write_headers(() => {
        @http2.encode_trailers(shared.encoder, stream.id, trailers)
      })
    },
  )
  shared.runtime_lock.acquire()
  let result = shared.runtime.finish_local_stream(stream.id)
  shared.runtime_lock.release()
  match result {
    Ok(_) => ()
    Err(error) => raise error
  }
  stream.request_finished = true
  shared.admission.signal()
  shared.release_stream(stream)
}

///|
async fn H2ClientShared::admit_stream(
  self : H2ClientShared,
  end_stream : Bool,
) -> Int32 {
  for ;; {
    self.runtime_lock.acquire()
    let opened = {
      defer self.runtime_lock.release()
      if self.failure is Some(error) {
        raise error
      }
      if self.draining {
        raise @http2.H2ProtocolError::ConnectionError(
          RefusedStream,
          "cannot create stream on a draining connection",
        )
      }
      if self.streams.length() >= self.config.max_concurrent_streams {
        None
      } else {
        match self.runtime.try_open_local_stream(end_stream~) {
          Ok(id) => id
          Err(error) => raise error
        }
      }
    }
    if opened is Some(id) {
      if id == 0x7fffffff {
        self.draining = true
        self.admission.broadcast()
        (self.state_changed)()
      }
      return id
    }
    // No suspension separates the capacity check from waiter registration.
    self.admission.wait()
  }
}

///|
#warnings("-unnecessary_annotation")
pub async fn[B : @body.Body] H2Client::send(
  self : H2Client,
  request : @types.Request[B],
) -> @types.Response[@body.BodyStream] {
  let mut upload_owned = false
  // Admission, encoding, and the first header write can all fail before an
  // upload task exists. Keep the caller's body owned across those boundaries.
  errdefer (if !upload_owned {
    request.body.cancel(@body.BodyError::Cancelled)
  })
  let hint = request.body.size_hint().exact_size()
  let exact_zero = hint == Some(0)
  let stream_id = self.shared.admit_stream(exact_zero)
  let credit = H2ReceiveCredit::new()
  let body = match
    @body.BodyStream::new(
      capacity=self.shared.config.body_queue_capacity,
      on_data_consumed=async fn(amount) {
        errdefer self.shared.cancel_stream(
          stream_id,
          @http2.H2ProtocolError::StreamError(
            stream_id,
            Cancel,
            "response body consumption callback failed",
          ),
        )
        self.shared.release_consumed_capacity(stream_id, credit, amount)
      },
      on_cancel=fn(error) {
        if credit.retired {
          return
        }
        self.shared.discard_capacity(credit.retire())
        self.shared.cancel_stream(stream_id, error)
      },
    ) {
    Ok(value) => value
    Err(error) => {
      ignore(self.shared.runtime.reset_stream(stream_id))
      self.shared.admission.signal()
      raise error
    }
  }
  let stream : H2ClientStream = {
    id: stream_id,
    head: Queue(kind=Blocking(1)),
    body,
    credit,
    window_signal: @cond_var.Cond(),
    request_method: request.http_method,
    response_body_bytes: 0,
    expected_response_bytes: None,
    response_body_allowed: true,
    response_started: false,
    request_finished: exact_zero,
    response_ended: false,
    response_finished: false,
    released: false,
    upload: None,
  }
  self.shared.streams.set(stream_id, stream)
  // Before HEADERS is handed to the writer there is no peer stream to reset.
  // A partial wire write already closes the connection in write_locked.
  let expected = {
    errdefer (if !stream.released {
      ignore(self.shared.runtime.reset_stream(stream_id))
      self.shared.fail_stream(stream, @body.BodyError::Cancelled)
    })
    let expected = h2_outgoing_length(stream_id, request.headers, hint)
    self.shared.write_headers(fn() {
      @http2.encode_request_headers(
        self.shared.encoder,
        stream_id,
        request,
        exact_zero,
      )
    })
    expected
  }
  // If the caller leaves while waiting for headers, use the same cancellation
  // path as an abandoned response body, including its asynchronous wire reset.
  errdefer body.cancel(@body.BodyError::Cancelled)
  if !exact_zero {
    let producer = async fn() {
      send_h2_request_body(self.shared, stream, request.body, expected)
    }
    upload_owned = true
    stream.upload = Some((self.shared.spawn)(producer))
  }
  let response = stream.head.get()
  response.map_body(fn(_) { body })
}

///|
/// Whether this session can admit new requests, including requests waiting for a peer slot.
pub fn H2Client::accepts_requests(self : H2Client) -> Bool {
  self.shared.failure is None && !self.shared.draining
}

///|
/// Both directions of every application stream have finished.
pub fn H2Client::is_idle(self : H2Client) -> Bool {
  self.shared.streams.is_empty()
}

///|
/// Wait for the peer's initial stream limits before issuing a burst on a new connection.
pub async fn H2Client::wait_for_settings(self : H2Client) -> Unit {
  while !self.shared.received_settings {
    if self.shared.failure is Some(error) {
      raise error
    }
    self.shared.admission.wait()
  }
}

///|
pub fn H2Client::close(self : H2Client) -> Unit {
  self.shared.close_with(None)
}

///|
pub async fn[R : @aio.BinaryReader, W : @aio.BinaryWriter, X] with_h2_client_connection(
  reader : R,
  writer : W,
  run : async (H2Client) -> X,
  config~ : H2ClientConfig = H2ClientConfig::defaults(),
  on_state_change~ : () -> Unit = fn() {  },
) -> X {
  match config.validate() {
    Ok(_) => ()
    Err(error) => raise error
  }
  @async_support.with_group_result(async fn(group) {
    let shared : H2ClientShared = {
      config,
      runtime: @http2.H2Connection::new(Client, limits=config.limits),
      encoder: @http2.HpackContext::new(
        max_table_size=config.limits.max_dynamic_table_bytes,
        max_header_list_size=config.limits.max_header_bytes,
      ),
      decoder: @http2.HpackContext::new(
        max_table_size=config.limits.max_dynamic_table_bytes,
        max_header_list_size=config.limits.max_header_bytes,
      ),
      frames: @http2.FrameDecoder::new(
        max_buffer_size=config.limits.max_buffer_bytes,
      ),
      streams: Map([]),
      blocked: Map([]),
      state_changed: on_state_change,
      received_settings: false,
      admission: Cond(),
      blocked_signal: Queue(kind=Unbounded),
      runtime_lock: Mutex(),
      write_lock: Mutex(),
      read: async fn(max_len) {
        read_some_with_timeout(reader, max_len, config.read_timeout_ms)
      },
      write: async fn(bytes) {
        write_with_timeout(writer, bytes, config.write_timeout_ms)
      },
      spawn: fn(task) { group.spawn(task, allow_failure=true) },
      failure: None,
      draining: false,
      close_notified: false,
      discarded_capacity: 0,
    }
    let client : H2Client = { shared, }
    group.add_defer(fn() { shared.close_with(None) })
    shared.write_bytes(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
    let receive_window = config.h2_receive_window_bytes
    shared.write_bytes(
      Bytes::from_array(
        @http2.encode_settings_frame(
          [
            { id: 1, value: config.limits.max_dynamic_table_bytes, },
            { id: 2, value: 0, }, // This client does not consume pushed streams.
            { id: 4, value: receive_window, },
          ],
          false,
        ),
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
      let encoded = match @http2.encode_window_update(0, increment) {
        Ok(value) => value
        Err(error) => raise error
      }
      shared.write_bytes(encoded)
    }
    let reader_task = group.spawn(
      async fn() {
        h2_client_reader_pump(shared) catch {
          error => shared.close_with(Some(error))
        }
      },
      no_wait=true,
      allow_failure=true,
    )
    group.spawn_bg(
      async fn() {
        while true {
          shared.blocked_signal.get() catch {
            _ => return
          }
          shared.release_discarded_capacity() catch {
            error => {
              shared.close_with(Some(error))
              return
            }
          }
          shared.drain_blocked()
        }
      },
      no_wait=true,
      allow_failure=true,
    )
    defer {
      // Close the connection before the task-group join. Upload producers are
      // waiting children and otherwise prevent the group defer below from
      // running when the caller returns after receiving a response.
      shared.close_with(None)
      reader_task.cancel()
    }
    run(client)
  })
}
