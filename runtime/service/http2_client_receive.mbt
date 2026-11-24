///|
fn decode_http2_response_head(
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
async fn Http2ClientState::deliver_headers(
  self : Http2ClientState,
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
    let (status, headers) = match
      decode_http2_response_head(stream_id, fields) {
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
async fn Http2ClientState::deliver_data(
  self : Http2ClientState,
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
async fn Http2ClientState::finish_header_block(
  self : Http2ClientState,
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
async fn h2_client_reader_pump(shared : Http2ClientState) -> Unit {
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
