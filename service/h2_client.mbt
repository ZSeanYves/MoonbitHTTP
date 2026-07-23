///|
/// A connection-level HTTP/2 client.
///
/// The connection owns the HPACK contexts and stream-id allocation. Calls are
/// serialized while the transport is driven synchronously; the returned body
/// is still exposed through the common `BodyStream` API and can be consumed
/// incrementally by the caller.
pub struct H2ClientConnection[R, W] {
  reader : R
  writer : W
  limits : @types.Limits
  max_concurrent_streams : Int
  runtime : @http2.H2Connection
  frames : @http2.FrameDecoder
  encoder : @http2.HpackContext
  decoder : @http2.HpackContext
  write_lock : @async.Mutex
  send_lock : @async.Mutex
  mut started : Bool
  mut closed : Bool
  mut goaway : Bool
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
async fn[R, W : @aio.Writer] H2ClientConnection::write(
  self : H2ClientConnection[R, W],
  bytes : Bytes,
) -> Unit {
  self.write_lock.acquire()
  defer self.write_lock.release()
  self.writer.write(bytes)
}

///|
pub fn[R, W] H2ClientConnection::new(
  reader : R,
  writer : W,
  limits? : @types.Limits = @types.Limits::defaults(),
  max_concurrent_streams? : Int = 100,
) -> H2ClientConnection[R, W] {
  if max_concurrent_streams < 1 {
    abort("max_concurrent_streams must be positive")
  }
  {
    reader,
    writer,
    limits,
    max_concurrent_streams,
    runtime: @http2.H2Connection::new(Client),
    frames: @http2.FrameDecoder::new(max_buffer_size=limits.max_buffer_bytes),
    encoder: @http2.HpackContext::new(
      max_header_list_size=limits.max_header_bytes,
    ),
    decoder: @http2.HpackContext::new(
      max_header_list_size=limits.max_header_bytes,
    ),
    write_lock: Mutex(),
    send_lock: Mutex(),
    started: false,
    closed: false,
    goaway: false,
  }
}

///|
pub async fn[R : @aio.Reader, W : @aio.Writer, B : @body.Body] H2ClientConnection::send(
  self : H2ClientConnection[R, W],
  request : @types.Request[B],
) -> @types.Response[@body.BodyStream] {
  if self.closed {
    raise @http2.H2ProtocolError::ConnectionError(
      Cancel,
      "HTTP/2 client connection is closed",
    )
  }
  self.send_lock.acquire()
  defer self.send_lock.release()
  if self.goaway {
    raise @http2.H2ProtocolError::ConnectionError(
      RefusedStream,
      "cannot create stream after GOAWAY",
    )
  }
  if self.max_concurrent_streams < 1 {
    raise @http2.H2ProtocolError::ConnectionError(
      RefusedStream,
      "HTTP/2 client stream limit reached",
    )
  }
  if !self.started {
    self.write(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
    self.write(Bytes::from_array(@http2.encode_settings_frame([], false)))
    self.started = true
  }
  let stream_id = match self.runtime.open_local_stream() {
    Ok(value) => value
    Err(error) => raise error
  }
  let exact_zero = request.body.size_hint().exact_size() == Some(0)
  let headers = match
    @http2.encode_request_headers(self.encoder, stream_id, request, exact_zero) {
    Ok(value) => value
    Err(error) => raise error
  }
  self.write(headers)
  let mut sent_trailers = false
  while request.body.next_frame() is Some(frame) {
    match frame {
      Data(data) => {
        if sent_trailers {
          raise @http2.H2ProtocolError::StreamError(
            stream_id,
            ProtocolError,
            "request data follows trailers",
          )
        }
        let mut offset = 0
        while offset < data.length() {
          let requested = (data.length() - offset).min(
            @http2.H2_DEFAULT_MAX_FRAME_SIZE,
          )
          let capacity = match
            self.runtime.reserve_send_capacity(stream_id, requested) {
            Ok(value) => value
            Err(error) => raise error
          }
          if capacity == 0 {
            raise @http2.H2ProtocolError::StreamError(
              stream_id,
              FlowControlError,
              "request body exceeds current HTTP/2 send window",
            )
          }
          let encoded = match
            @http2.encode_data_frames(
              stream_id,
              data[offset:offset + capacity].to_owned(),
              false,
            ) {
            Ok(value) => value
            Err(error) => raise error
          }
          self.write(encoded)
          offset += capacity
        }
      }
      Trailers(trailers) => {
        sent_trailers = true
        let encoded = match
          @http2.encode_trailers(self.encoder, stream_id, trailers) {
          Ok(value) => value
          Err(error) => raise error
        }
        self.write(encoded)
      }
    }
  }
  if !exact_zero && !sent_trailers {
    let encoded_end = match @http2.encode_data_frames(stream_id, b"", true) {
      Ok(value) => value
      Err(error) => raise error
    }
    self.write(encoded_end)
  }
  match self.runtime.finish_local_stream(stream_id) {
    Ok(_) => ()
    Err(error) => raise error
  }
  let mut response_head : @types.Response[Unit]? = None
  let response_body : Array[Byte] = []
  let mut trailers : @types.HeaderMap? = None
  let header_block : Array[Byte] = []
  let mut header_stream = 0
  let mut header_end_stream = false
  let mut response_ended = false
  for ;; {
    match self.reader.read_some(max_len=8192) {
      None => {
        self.closed = true
        raise @http2.H2ProtocolError::ConnectionError(
          ProtocolError,
          "HTTP/2 server closed connection",
        )
      }
      Some(bytes) => {
        match self.frames.feed(bytes) {
          Ok(_) => ()
          Err(error) => raise error
        }
        while self.frames.next() is Ok(Some(frame)) {
          let actions = match self.runtime.receive(frame) {
            Ok(value) => value
            Err(error) => raise error
          }
          for action in actions {
            match action {
              SendSettingsAck =>
                self.write(
                  Bytes::from_array(@http2.encode_settings_frame([], true)),
                )
              SendPingAck(payload) => {
                let encoded = match @http2.encode_ping_ack(payload) {
                  Ok(value) => value
                  Err(error) => raise error
                }
                self.write(encoded)
              }
              GoawayReceived(_, _) => self.goaway = true
              HeadersStarted(id, end_stream) => {
                header_stream = id
                header_end_stream = end_stream
                if id == stream_id {
                  response_ended = end_stream
                }
                header_block.clear()
                let fragment = match @http2.header_fragment(frame) {
                  Ok(value) => value
                  Err(error) => raise error
                }
                for byte in fragment {
                  header_block.push(byte)
                }
                if (frame.header.flags & @http2.H2_FLAGS_END_HEADERS) != 0 {
                  let fields = match
                    self.decoder.decode(Bytes::from_array(header_block)) {
                    Ok(value) => value
                    Err(error) => raise error
                  }
                  if id == stream_id && response_head is None {
                    let (status, headers) = match
                      decode_client_response(id, fields) {
                      Ok(value) => value
                      Err(error) => raise error
                    }
                    if status >= 200 || status == 101 {
                      response_head = Some({
                        status,
                        version: Http2,
                        headers,
                        body: (),
                      })
                    }
                  } else if id == stream_id {
                    trailers = Some(
                      match decode_client_trailers(fields) {
                        Ok(value) => value
                        Err(error) => raise error
                      },
                    )
                  }
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
                  if id == stream_id {
                    response_ended = header_end_stream
                  }
                  let fields = match
                    self.decoder.decode(Bytes::from_array(header_block)) {
                    Ok(value) => value
                    Err(error) => raise error
                  }
                  if id == stream_id && response_head is None {
                    let (status, headers) = match
                      decode_client_response(id, fields) {
                      Ok(value) => value
                      Err(error) => raise error
                    }
                    response_head = Some({
                      status,
                      version: Http2,
                      headers,
                      body: (),
                    })
                  } else if id == stream_id {
                    trailers = Some(
                      match decode_client_trailers(fields) {
                        Ok(value) => value
                        Err(error) => raise error
                      },
                    )
                  }
                }
              }
              DataReceived(id, data, end_stream) if id == stream_id => {
                for byte in data {
                  response_body.push(byte)
                }
                response_ended = end_stream
              }
              _ => ()
            }
          }
          if response_ended && response_head is Some(head) {
            let body = @body.BodyStream::new(
              capacity=2,
              size_hint=@body.SizeHint::exact(response_body.length()),
            )
            if !response_body.is_empty() {
              body.push(Data(Bytes::from_array(response_body)))
            }
            if trailers is Some(value) {
              body.push(Trailers(value))
            }
            body.finish()
            return head.map_body(fn(_) { body })
          }
        }
      }
    }
  }
}

///|
fn decode_client_trailers(
  fields : Array[@http2.HpackHeader],
) -> Result[@types.HeaderMap, @http2.H2ProtocolError] {
  let headers = @types.HeaderMap::new()
  for field in fields {
    if field.name.has_prefix(":") {
      return Err(
        ConnectionError(ProtocolError, "pseudo-header in response trailers"),
      )
    }
    match headers.append_string(field.name, field.value) {
      Ok(_) => ()
      Err(_) =>
        return Err(ConnectionError(ProtocolError, "invalid response trailers"))
    }
  }
  Ok(headers)
}

///|
pub fn[R, W] H2ClientConnection::close(self : H2ClientConnection[R, W]) -> Unit {
  self.closed = true
}
