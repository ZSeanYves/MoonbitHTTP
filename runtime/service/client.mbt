///|
/// A sequential HTTP/1 connection. A response body must be fully consumed
/// before the next request is sent on the same connection.
pub struct ClientConnection[R, W] {
  priv reader : R
  priv writer : W
  priv limits : @types.Limits
  priv read_size : Int
  priv request_headers_timeout_ms : Int?
  priv request_body_timeout_ms : Int?
  priv response_headers_timeout_ms : Int?
  priv response_body_timeout_ms : Int?
  priv mut state : Http1ClientState
}

///|
priv enum Http1ClientState {
  Ready
  Active
  CloseAfterBody
  Closed
}

///|
pub(all) suberror ClientConnectionError {
  ConnectionClosed
  RequestInProgress
} derive(Eq, Debug)

///|
fn[R, W] ClientConnection::finish_response(
  self : ClientConnection[R, W],
) -> Unit {
  match self.state {
    Active => self.state = Ready
    CloseAfterBody => self.state = Closed
    Ready | Closed => ()
  }
}

///|
pub(all) enum ClientConnectionPhase {
  RequestHeaders
  RequestBody
  ResponseHeaders
  ResponseBody
} derive(Eq, Debug)

///|
pub(all) suberror ClientConnectionTimeout {
  ClientConnectionTimeout(ClientConnectionPhase)
} derive(Eq, Debug)

///|
/// Builds a sequential HTTP/1 client with independent phase timeouts. `None`
/// disables only the named phase; all positive values are milliseconds.
pub fn[R, W] ClientConnection::new(
  reader : R,
  writer : W,
  limits? : @types.Limits = @types.Limits::defaults(),
  read_size? : Int = 8192,
  request_headers_timeout_ms? : Int? = Some(30000),
  request_body_timeout_ms? : Int? = Some(30000),
  response_headers_timeout_ms? : Int? = Some(30000),
  response_body_timeout_ms? : Int? = Some(30000),
) -> Result[ClientConnection[R, W], ServiceConfigError] {
  let timeouts : Array[(String, Int?)] = [
    ("request headers", request_headers_timeout_ms),
    ("request body", request_body_timeout_ms),
    ("response headers", response_headers_timeout_ms),
    ("response body", response_body_timeout_ms),
  ]
  for entry in timeouts {
    let (name, timeout) = entry
    if timeout is Some(value) && value <= 0 {
      return Err(InvalidTimeout(name, value))
    }
  }
  let config = ServerConfig::{
    ..ServerConfig::defaults(),
    limits,
    read_size,
    body_queue_capacity: 1,
    h2_receive_window_bytes: 65535,
    read_timeout_ms: response_headers_timeout_ms,
    write_timeout_ms: request_headers_timeout_ms,
    close_callback: None,
  }
  match config.validate() {
    Ok(_) =>
      Ok({
        reader,
        writer,
        limits,
        read_size,
        request_headers_timeout_ms,
        request_body_timeout_ms,
        response_headers_timeout_ms,
        response_body_timeout_ms,
        state: Ready,
      })
    Err(error) => Err(error)
  }
}

///|
async fn[R : @aio.Reader] client_read_with_timeout(
  reader : R,
  max_len : Int,
  timeout_ms : Int?,
  phase : ClientConnectionPhase,
) -> Bytes? {
  read_some_with_timeout(reader, max_len, timeout_ms) catch {
    @async.TimeoutError => raise ClientConnectionTimeout(phase)
    error => raise error
  }
}

///|
async fn[W : @aio.Writer] client_write_with_timeout(
  writer : W,
  bytes : Bytes,
  timeout_ms : Int?,
  phase : ClientConnectionPhase,
) -> Unit {
  write_with_timeout(writer, bytes, timeout_ms) catch {
    @async.TimeoutError => raise ClientConnectionTimeout(phase)
    error => raise error
  }
}

///|
/// Marks the HTTP/1 client connection unusable. Physical transport shutdown is
/// owned by the caller's Reader/Writer adapter.
pub fn[R, W] ClientConnection::close(self : ClientConnection[R, W]) -> Unit {
  self.state = Closed
}

///|
/// A connection is reusable only after the previous response reached its
/// terminal frame and neither peer requested closure.
pub fn[R, W] ClientConnection::is_reusable(
  self : ClientConnection[R, W],
) -> Bool {
  self.state is Ready
}

///|
pub fn[R, W] ClientConnection::is_closed(self : ClientConnection[R, W]) -> Bool {
  match self.state {
    Closed | CloseAfterBody => true
    Ready | Active => false
  }
}

///|
pub async fn[R : @aio.Reader, W : @aio.Writer, B : @body.Body] ClientConnection::send(
  self : ClientConnection[R, W],
  request : @types.Request[B],
) -> @types.Response[@body.BodyStream] {
  match self.state {
    Ready => self.state = Active
    Active => raise RequestInProgress
    Closed | CloseAfterBody => raise ConnectionClosed
  }
  // Reserve the connection before the first suspension, including header writes.
  errdefer self.close()
  let request_closes = header_has_token(request.headers, "connection", "close") ||
    (
      request.version == Http10 &&
      !header_has_token(request.headers, "connection", "keep-alive")
    )
  with_outgoing_body_scope(request.body, async fn() {
    let framing = match request.body.size_hint().exact_size() {
      Some(size) => @http1.BodyFraming::ContentLength(size)
      None =>
        if request.version == Http11 {
          Chunked
        } else {
          raise @http1.Http1Error::InvalidFraming(
            "HTTP/1.0 requests require an exact body size",
          )
        }
    }
    let request_head : @types.Request[Unit] = {
      http_method: request.http_method,
      uri: request.uri,
      version: request.version,
      headers: request.headers,
      body: (),
    }
    let encoded_head = match @http1.encode_request_head(request_head, framing) {
      Ok(bytes) => bytes
      Err(error) => raise error
    }
    client_write_with_timeout(
      self.writer,
      encoded_head,
      self.request_headers_timeout_ms,
      RequestHeaders,
    )
    write_http1_body(request.body, framing, async fn(bytes) {
      client_write_with_timeout(
        self.writer,
        bytes,
        self.request_body_timeout_ms,
        RequestBody,
      )
    })
  })
  let decoder = @http1.ResponseDecoder::new(
    request.http_method,
    limits=self.limits,
  )
  for ;; {
    match decoder.next() {
      Err(error) => raise error
      Ok(Some(ResponseHead(value))) =>
        if value.status >= 100 && value.status < 200 && value.status != 101 {
          ()
        } else {
          if value.status == 101 ||
            header_has_token(value.headers, "connection", "close") ||
            request_closes ||
            (
              value.version == Http10 &&
              !header_has_token(value.headers, "connection", "keep-alive")
            ) ||
            !value.headers.get_all_string("upgrade").is_empty() {
            self.state = CloseAfterBody
          }
          let stream = @body.BodyStream::from_pull(
            async fn() {
              for ;; {
                match decoder.next() {
                  Err(error) => {
                    self.close()
                    raise error
                  }
                  Ok(Some(ResponseData(data))) => return Some(Data(data))
                  Ok(Some(ResponseTrailers(value))) => {
                    // Trailers are terminal for the body abstraction. The
                    // decoder's following ResponseEnd carries no wire bytes.
                    self.finish_response()
                    return Some(Trailers(value))
                  }
                  Ok(Some(ResponseEnd)) => {
                    self.finish_response()
                    return None
                  }
                  Ok(Some(ResponseHead(_))) => ()
                  Ok(None) =>
                    match
                      client_read_with_timeout(
                        self.reader,
                        self.read_size,
                        self.response_body_timeout_ms,
                        ResponseBody,
                      ) {
                      Some(bytes) =>
                        match decoder.feed(bytes) {
                          Ok(_) => ()
                          Err(error) => {
                            self.close()
                            raise error
                          }
                        }
                      None => {
                        self.close()
                        decoder.finish_input()
                      }
                    }
                }
              }
            },
            on_terminate=fn(error) { if error is Some(_) { self.close() } },
          )
          return value.map_body(fn(_) { stream })
        }
      Ok(Some(ResponseData(_))) | Ok(Some(ResponseTrailers(_))) =>
        raise @http1.Http1Error::InvalidFraming(
          "response body event arrived before final response head",
        )
      // Informational responses have no body and therefore emit an end marker
      // before the final response. The decoder guarantees that this marker
      // follows a corresponding 1xx head.
      Ok(Some(ResponseEnd)) => ()
      Ok(None) =>
        match
          client_read_with_timeout(
            self.reader,
            self.read_size,
            self.response_headers_timeout_ms,
            ResponseHeaders,
          ) {
          Some(bytes) =>
            match decoder.feed(bytes) {
              Ok(_) => ()
              Err(error) => raise error
            }
          None => {
            self.close()
            raise @http1.Http1Error::UnexpectedEof("final response head")
          }
        }
    }
  } nobreak {
    raise @http1.Http1Error::UnexpectedEof("client response loop ended")
  }
}
