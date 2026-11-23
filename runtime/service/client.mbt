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
    if validate_timeout(name, timeout) is Err(error) {
      return Err(error)
    }
  }
  match validate_read_limits(limits, read_size) {
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
async fn[R, W : @aio.Writer, B : @body.Body] ClientConnection::write_upload(
  self : ClientConnection[R, W],
  framing : @http1.BodyFraming,
  body : B,
) -> Unit {
  write_http1_body(
    framing,
    async fn() {
      match self.request_body_timeout_ms {
        Some(timeout) =>
          @async.with_timeout(
            timeout,
            () => body.next_frame(),
            error=ClientConnectionTimeout(RequestBody),
          )
        None => body.next_frame()
      }
    },
    async fn(bytes) {
      client_write_with_timeout(
        self.writer,
        bytes,
        self.request_body_timeout_ms,
        RequestBody,
      )
    },
  )
}

///|
async fn[R : @aio.Reader, W] ClientConnection::read_response_head(
  self : ClientConnection[R, W],
  decoder : @http1.ResponseDecoder,
  timeout_ms : Int?,
  stop_at_continue? : Bool = false,
) -> @types.Response[Unit] {
  let mut received_continue = None
  for ;; {
    match decoder.next().unwrap_or_error() {
      Some(ResponseHead(head)) => {
        if head.status == 101 || head.status >= 200 {
          return head
        }
        if stop_at_continue && head.status == 100 {
          // Prefer a final response already in this read over opening the body.
          received_continue = Some(head)
        }
      }
      Some(ResponseEnd) => () // End of an informational response.
      Some(ResponseData(_)) | Some(ResponseTrailers(_)) =>
        raise @http1.Http1Error::InvalidFraming(
          "body before final response head",
        )
      None => {
        if received_continue is Some(head) {
          return head
        }
        match
          client_read_with_timeout(
            self.reader,
            self.read_size,
            timeout_ms,
            ResponseHeaders,
          ) {
          Some(bytes) => decoder.feed(bytes).unwrap_or_error()
          None => raise @http1.Http1Error::UnexpectedEof("final response head")
        }
      }
    }
  }
}

///|
/// Keep a single pending read across the grace period. Cancelling an actual
/// transport read on timeout would close the socket before the upload.
async fn[R : @aio.Reader, W : @aio.Writer, B : @body.Body] ClientConnection::expect_continue(
  self : ClientConnection[R, W],
  decoder : @http1.ResponseDecoder,
  framing : @http1.BodyFraming,
  body : B,
) -> @types.Response[Unit] {
  @async.with_task_group(async fn(group) {
    let changed = @cond_var.Cond()
    let mut outcome : Result[@types.Response[Unit], Error]? = None
    group.spawn_bg(async fn() {
      let result = Ok(
        self.read_response_head(decoder, None, stop_at_continue=true),
      ) catch {
        error => Err(error)
      }
      outcome = Some(result)
      changed.signal()
    })
    let wait_for_head = async fn() {
      while outcome is None {
        changed.wait()
      }
    }
    with_outgoing_body_scope(body, async fn() {
      let grace_ms = self.response_headers_timeout_ms.unwrap_or(1000).min(1000)
      ignore(@async.with_timeout_opt(grace_ms, wait_for_head))
      match outcome {
        Some(Err(error)) => raise error
        Some(Ok(head)) if head.status != 100 => {
          self.state = CloseAfterBody
          body.cancel(@body.BodyError::Cancelled)
        }
        _ => self.write_upload(framing, body)
      }
    })
    if outcome is None {
      match self.response_headers_timeout_ms {
        Some(timeout) =>
          @async.with_timeout(
            timeout,
            wait_for_head,
            error=ClientConnectionTimeout(ResponseHeaders),
          )
        None => wait_for_head()
      }
    }
    let first_head = outcome.unwrap().unwrap_or_error()
    if first_head.status == 100 {
      self.read_response_head(decoder, self.response_headers_timeout_ms)
    } else {
      first_head
    }
  })
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
  errdefer self.close()
  let request_closes = !http1_allows_persistence(
    request.version,
    request.headers,
  )
  let (framing, expect_continue) = with_outgoing_body_scope(request.body, async fn() {
    let framing = match request.body.size_hint().exact_size() {
      Some(size) => @http1.BodyFraming::ContentLength(size)
      None if request.version == Http11 => Chunked
      None =>
        raise @http1.Http1Error::InvalidFraming(
          "HTTP/1.0 requests require an exact body size",
        )
    }
    let request_head = request.map_body(fn(_) { () })
    let encoded_head = @http1.encode_request_head(request_head, framing).unwrap_or_error()
    let expect_continue = request.version == Http11 &&
      framing != ContentLength(0) &&
      @types.RequestExpectations::from_headers(request.headers).continue_requested
    client_write_with_timeout(
      self.writer,
      encoded_head,
      self.request_headers_timeout_ms,
      RequestHeaders,
    )
    (framing, expect_continue)
  })
  let decoder = @http1.ResponseDecoder::new(
    request.http_method,
    limits=self.limits,
  )
  let head = if expect_continue {
    self.expect_continue(decoder, framing, request.body)
  } else {
    with_outgoing_body_scope(request.body, async fn() {
      self.write_upload(framing, request.body)
    })
    self.read_response_head(decoder, self.response_headers_timeout_ms)
  }
  if request_closes ||
    !http1_allows_persistence(head.version, head.headers) ||
    head.status == 101 ||
    (request.http_method == Connect && head.status >= 200 && head.status < 300) ||
    head.headers.get_string("upgrade") is Some(_) {
    self.state = CloseAfterBody
  }
  let stream = @body.BodyStream::from_pull(
    async fn() {
      for ;; {
        match decoder.next().unwrap_or_error() {
          Some(ResponseData(data)) => return Some(Data(data))
          Some(ResponseTrailers(trailers)) => {
            self.finish_response()
            return Some(Trailers(trailers))
          }
          Some(ResponseEnd) => {
            self.finish_response()
            return None
          }
          Some(ResponseHead(_)) =>
            raise @http1.Http1Error::InvalidFraming(
              "response head inside response body",
            )
          None =>
            match
              client_read_with_timeout(
                self.reader,
                self.read_size,
                self.response_body_timeout_ms,
                ResponseBody,
              ) {
              Some(bytes) => decoder.feed(bytes).unwrap_or_error()
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
  head.map_body(fn(_) { stream })
}
