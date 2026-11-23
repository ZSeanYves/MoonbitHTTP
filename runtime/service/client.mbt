///|
/// A sequential HTTP/1 connection. A response body must be fully consumed
/// before the next request is sent on the same connection.
pub struct ClientConnection[R, W] {
  priv reader : R
  priv writer : W
  priv limits : @types.Limits
  priv read_size : Int32
  priv request_headers_timeout_ms : Int32?
  priv request_body_timeout_ms : Int32?
  priv response_headers_timeout_ms : Int32?
  priv response_body_timeout_ms : Int32?
  priv on_incomplete_upload : () -> Unit
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
#derive(Eq, Debug)
pub(all) suberror ClientConnectionError {
  ConnectionClosed
  RequestInProgress
}

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
#derive(Eq, Debug)
pub(all) enum ClientConnectionPhase {
  RequestHeaders
  RequestBody
  ResponseHeaders
  ResponseBody
}

///|
#derive(Eq, Debug)
pub(all) suberror ClientConnectionTimeout {
  ClientConnectionTimeout(ClientConnectionPhase)
}

///|
/// Builds a sequential HTTP/1 client with independent phase timeouts. `None`
/// disables only the named phase; all positive values are milliseconds.
pub fn[R, W] ClientConnection::new(
  reader : R,
  writer : W,
  limits~ : @types.Limits = @types.Limits::defaults(),
  read_size~ : Int32 = 8192,
  request_headers_timeout_ms~ : Int32? = Some(30000),
  request_body_timeout_ms~ : Int32? = Some(30000),
  response_headers_timeout_ms~ : Int32? = Some(30000),
  on_incomplete_upload~ : () -> Unit = fn() {  },
  response_body_timeout_ms~ : Int32? = Some(30000),
) -> Result[ClientConnection[R, W], ServiceConfigError] {
  let timeouts : Array[(String, Int32?)] = [
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
        on_incomplete_upload,
        state: Ready,
      })
    Err(error) => Err(error)
  }
}

///|
async fn[R : @aio.BinaryReader] client_read_with_timeout(
  reader : R,
  max_len : Int32,
  timeout_ms : Int32?,
  phase : ClientConnectionPhase,
) -> Bytes? {
  read_some_with_timeout(reader, max_len, timeout_ms) catch {
    @async.TimeoutError => raise ClientConnectionTimeout(phase)
    error => raise error
  }
}

///|
async fn[W : @aio.BinaryWriter] client_write_with_timeout(
  writer : W,
  bytes : Bytes,
  timeout_ms : Int32?,
  phase : ClientConnectionPhase,
  on_written~ : () -> Unit = fn() {  },
) -> Unit {
  io_with_timeout(timeout_ms, async fn() {
    writer.write(bytes)
    on_written()
  }) catch {
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
async fn[R, W : @aio.BinaryWriter, B : @body.Body] ClientConnection::write_upload(
  self : ClientConnection[R, W],
  framing : @http1.BodyFraming,
  body : B,
  on_wire_end~ : () -> Unit = fn() {  },
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
    async fn(bytes, ends_message) {
      client_write_with_timeout(
        self.writer,
        bytes,
        self.request_body_timeout_ms,
        RequestBody,
        on_written=fn() { if ends_message { on_wire_end() } },
      )
    },
  )
}

///|
async fn[R : @aio.BinaryReader, W] ClientConnection::read_response_head(
  self : ClientConnection[R, W],
  decoder : @http1.ResponseDecoder,
  timeout_ms : Int32?,
  on_continue~ : () -> Unit = fn() {  },
) -> @types.Response[Unit] {
  let mut saw_continue = false
  for ;; {
    match decoder.next().unwrap_or_error() {
      Some(ResponseHead(head)) => {
        if head.status == 101 || head.status >= 200 {
          return head
        }
        if head.status == 100 {
          saw_continue = true
        }
      }
      Some(ResponseEnd) => () // End of an informational response.
      Some(ResponseData(_)) | Some(ResponseTrailers(_)) =>
        raise @http1.Http1Error::InvalidFraming(
          "body before final response head",
        )
      None => {
        if saw_continue {
          saw_continue = false
          on_continue()
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
/// One reader owns the decoder for the entire exchange, including the
/// Continue grace period. Only the upload worker is cancelled on an early head.
async fn[R : @aio.BinaryReader, W : @aio.BinaryWriter, B : @body.Body] ClientConnection::exchange_upload(
  self : ClientConnection[R, W],
  decoder : @http1.ResponseDecoder,
  framing : @http1.BodyFraming,
  body : B,
  expect_continue : Bool,
) -> @types.Response[Unit] {
  @async_support.with_group_result(async fn(group) {
    let changed = @cond_var.Cond()
    let mut continued = false
    let mut head : @types.Response[Unit]? = None
    let mut uploaded = false
    let mut wire_complete = false
    // Hold the reader open across the upload. A response-header deadline
    // starts after the request has actually been written.
    let mut failure : Error? = None
    with_outgoing_body_scope(body, async fn() {
      let upload = group.spawn(async fn() {
        try {
          if expect_continue {
            ignore(
              @async.with_timeout_opt(
                self.response_headers_timeout_ms.unwrap_or(1000).min(1000),
                async fn() {
                  while !continued && head is None {
                    changed.wait()
                  }
                },
              ),
            )
          }
          if head is None {
            self.write_upload(framing, body, on_wire_end=fn() {
              wire_complete = true
            })
            uploaded = true
          }
        } catch {
          error => if head is None && failure is None { failure = Some(error) }
        }
        changed.broadcast()
      })
      group.spawn_bg(
        async fn() {
          try {
            head = Some(
              self.read_response_head(decoder, None, on_continue=fn() {
                continued = true
                changed.broadcast()
              }),
            )
          } catch {
            error => if failure is None { failure = Some(error) }
          }
          changed.broadcast()
        },
        no_wait=true,
      )
      while !uploaded && head is None && failure is None {
        changed.wait()
      }
      if failure is Some(error) {
        raise error
      }
      if !uploaded {
        if !wire_complete {
          self.state = CloseAfterBody
          (self.on_incomplete_upload)()
        }
        upload.cancel()
        body.cancel(@body.BodyError::Cancelled)
      }
    })
    let wait = async fn() {
      while head is None && failure is None {
        changed.wait()
      }
      if failure is Some(error) {
        raise error
      }
      head.unwrap()
    }
    match self.response_headers_timeout_ms {
      Some(ms) =>
        @async.with_timeout(
          ms,
          wait,
          error=ClientConnectionTimeout(ResponseHeaders),
        )
      None => wait()
    }
  })
}

///|
pub async fn[R : @aio.BinaryReader, W : @aio.BinaryWriter, B : @body.Body] ClientConnection::send(
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
  let head = if framing != ContentLength(0) {
    self.exchange_upload(decoder, framing, request.body, expect_continue)
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
