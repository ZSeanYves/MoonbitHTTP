///|
pub(all) struct ServerConfig {
  limits : @types.Limits
  read_size : Int32
  body_queue_capacity : Int32
  h2_receive_window_bytes : Int32
  read_timeout_ms : Int32?
  write_timeout_ms : Int32?
  /// Maximum time to finish H2 handlers and response bodies after peer EOF.
  h2_eof_drain_timeout_ms : Int32
  close_callback : ((Error?) -> Unit)?
}

///|
pub fn ServerConfig::defaults() -> ServerConfig {
  {
    limits: @types.Limits::defaults(),
    read_size: 8192,
    body_queue_capacity: 8,
    h2_receive_window_bytes: 65535,
    read_timeout_ms: Some(30000),
    write_timeout_ms: Some(30000),
    h2_eof_drain_timeout_ms: 30000,
    close_callback: None,
  }
}

///|
fn ServerConfig::without_close_callback(self : ServerConfig) -> ServerConfig {
  { ..self, close_callback: None, }
}

///|
async fn[X] io_with_timeout(timeout_ms : Int32?, action : async () -> X) -> X {
  try {
    match timeout_ms {
      Some(timeout) if timeout > 0 => @async.with_timeout(timeout, action)
      _ => action()
    }
  } catch {
    error => raise @async_support.io_cause(error)
  }
}

///|
async fn[R : @aio.BinaryReader] read_some_with_timeout(
  reader : R,
  max_len : Int32,
  timeout_ms : Int32?,
) -> Bytes? {
  io_with_timeout(timeout_ms, () => @async_support.read_some(reader, max_len))
}

///|
async fn[R : @aio.BinaryReader] read_exactly_with_timeout(
  reader : R,
  len : Int32,
  timeout_ms : Int32?,
) -> Bytes {
  io_with_timeout(timeout_ms, () => reader.read_exactly(len))
}

///|
async fn[W : @aio.BinaryWriter] write_with_timeout(
  writer : W,
  bytes : Bytes,
  timeout_ms : Int32?,
) -> Unit {
  io_with_timeout(timeout_ms, () => writer.write(bytes))
}

///|
fn copy_data(target : Array[Byte], source : BytesView) -> Unit {
  for byte in source {
    target.push(byte)
  }
}

///|
fn expects_request_body(request : @types.Request[Unit]) -> Bool {
  match request.headers.content_length() {
    Ok(Some(size)) if size > 0 => true
    _ => !request.headers.get_all_string("transfer-encoding").is_empty()
  }
}

///|
async fn[W : @aio.BinaryWriter] accept_http1_expectation(
  request : @types.Request[Unit],
  writer : W,
  timeout_ms : Int32?,
) -> Bool {
  let status = expectation_response(request.headers, () => {
    request.version == Http11 && expects_request_body(request)
  })
  if status == Some(417) {
    let headers = @types.HeaderMap::new()
    headers.append_string("connection", "close").unwrap()
    let response_head : @types.Response[Unit] = {
      status: 417,
      version: request.version,
      headers,
      body: (),
    }
    let encoded = match
      @http1.encode_response_head(
        response_head,
        request.http_method,
        if request.http_method == Head {
          NoBody
        } else {
          ContentLength(0)
        },
      ) {
      Ok(value) => value
      Err(error) => raise error
    }
    write_with_timeout(writer, encoded, timeout_ms)
    return false
  }
  if status == Some(100) {
    write_with_timeout(writer, b"HTTP/1.1 100 Continue\r\n\r\n", timeout_ms)
  }
  true
}

///|
fn http1_allows_persistence(
  version : @types.Version,
  headers : @types.HeaderMap,
) -> Bool {
  !headers.contains_list_token("connection", "close") &&
  (
    version == Http11 ||
    (
      version == Http10 &&
      headers.contains_list_token("connection", "keep-alive")
    )
  )
}

///|
priv struct Http1RequestInput[R] {
  reader : R
  decoder : @http1.RequestDecoder
  read_size : Int32
  timeout_ms : Int32?
  mut eof : Bool
}

///|
fn[R] Http1RequestInput::new(
  reader : R,
  config : ServerConfig,
) -> Http1RequestInput[R] {
  {
    reader,
    decoder: @http1.RequestDecoder::new(limits=config.limits),
    read_size: config.read_size,
    timeout_ms: config.read_timeout_ms,
    eof: false,
  }
}

///|
async fn[R : @aio.BinaryReader] Http1RequestInput::next(
  self : Http1RequestInput[R],
) -> @http1.RequestEvent? {
  for ;; {
    match self.decoder.next().unwrap_or_error() {
      Some(event) => return Some(event)
      None if self.eof => return None
      None =>
        match
          read_some_with_timeout(self.reader, self.read_size, self.timeout_ms) {
          Some(bytes) => self.decoder.feed(bytes).unwrap_or_error()
          None => {
            self.eof = true
            self.decoder.finish_input()
          }
        }
    }
  }
}

///|
pub async fn[R : @aio.BinaryReader] drive_http1_events(
  reader : R,
  on_event : async (@http1.RequestEvent) -> Unit,
  config~ : ServerConfig = ServerConfig::defaults(),
) -> Unit {
  config.validate_http1().unwrap_or_error()
  let input = Http1RequestInput::new(reader, config)
  while input.next() is Some(event) {
    on_event(event)
  }
}

///|
async fn[R : @aio.BinaryReader, W : @aio.BinaryWriter, B : @body.Body] serve_http1_connection_inner(
  input : Http1RequestInput[R],
  writer : W,
  service : async (@types.Request[@body.BodyStream]) -> @types.Response[B],
  config : ServerConfig,
  first_head~ : @types.Request[Unit]? = None,
) -> Unit {
  let mut active : @async.Task[Unit]? = None
  let mut active_stream : @body.BodyStream? = None
  let mut handler_done = false
  let mut finish_after_response = false
  @async.with_task_group(async fn(group) {
    group.add_defer(fn() {
      if active_stream is Some(stream) && !handler_done {
        stream.fail(
          @http1.Http1Error::UnexpectedEof("HTTP/1 connection closed"),
        )
      }
    })
    let drive_result : Result[Unit, Error] = try {
      let mut pending = match first_head {
        Some(head) => Some(@http1.RequestHead(head))
        None => input.next()
      }
      while pending is Some(event) {
        match event {
          RequestHead(request) => {
            guard accept_http1_expectation(
              request,
              writer,
              config.write_timeout_ms,
            ) else {
              return ()
            }
            handler_done = false
            let stream = match
              @body.BodyStream::new(capacity=config.body_queue_capacity) {
              Ok(value) => value
              Err(error) => raise error
            }
            active_stream = Some(stream)
            let request = request.map_body(fn(_) { stream })
            active = Some(
              group.spawn(async fn() {
                defer {
                  handler_done = true
                  // The outgoing body may consume request input lazily.
                  // Once it ends, wake any producer blocked on unread input.
                  stream.cancel(@body.BodyError::Cancelled)
                }
                let response = service(request)
                with_outgoing_body_scope(response.body, async fn() {
                  if response.status < 200 && response.status != 101 {
                    raise @http1.Http1Error::InvalidStartLine(
                      "handler must return a final response",
                    )
                  }
                  let request_method = request.http_method
                  let version = request.version
                  let mut framing = @http1.NoBody
                  if response.status != 101 &&
                    @types.response_allows_body(request_method, response.status) {
                    match response.body.size_hint().exact_size() {
                      Some(size) => framing = ContentLength(size)
                      None =>
                        framing = if version == Http11 {
                          Chunked
                        } else {
                          CloseDelimited
                        }
                    }
                  }
                  let close = !http1_allows_persistence(
                      version,
                      request.headers,
                    ) ||
                    framing == CloseDelimited ||
                    response.headers.contains_list_token("connection", "close")
                  finish_after_response = close ||
                    response.status == 101 ||
                    (
                      request_method == Connect &&
                      response.status >= 200 &&
                      response.status < 300
                    ) ||
                    !response.headers.get_all_string("upgrade").is_empty()
                  if close {
                    response.headers.set(
                      @types.HeaderName::parse("connection").unwrap(),
                      @types.HeaderValue::from_string("close").unwrap(),
                    )
                  } else if version == Http10 &&
                    !response.headers.contains_list_token(
                      "connection", "keep-alive",
                    ) {
                    ignore(
                      response.headers.append_string("connection", "keep-alive"),
                    )
                  }
                  let response_head : @types.Response[Unit] = {
                    status: response.status,
                    version,
                    headers: response.headers,
                    body: (),
                  }
                  let encoded_head = match
                    @http1.encode_response_head(
                      response_head, request_method, framing,
                    ) {
                    Ok(value) => value
                    Err(error) => raise error
                  }
                  write_with_timeout(
                    writer,
                    encoded_head,
                    config.write_timeout_ms,
                  )
                  if framing == NoBody {
                    response.body.cancel(@body.BodyError::Cancelled)
                    return ()
                  }
                  write_http1_body(framing, () => response.body.next_frame(), async fn(
                    bytes,
                    _,
                  ) {
                    write_with_timeout(writer, bytes, config.write_timeout_ms)
                  })
                })
              }),
            )
          }
          RequestData(data) =>
            if !handler_done && active_stream is Some(stream) {
              stream.push(Data(data)) catch {
                @body.BodyError::Cancelled if handler_done => ()
                error => raise error
              }
            }
          RequestTrailers(trailers) =>
            if !handler_done && active_stream is Some(stream) {
              stream.push(Trailers(trailers)) catch {
                @body.BodyError::Cancelled if handler_done => ()
                error => raise error
              }
            }
          RequestEnd => {
            if active_stream is Some(stream) {
              stream.finish()
            }
            guard active is Some(task) else {
              raise @http1.InvalidFraming("request ended without request head")
            }
            task.wait()
            active = None
            active_stream = None
            if finish_after_response {
              return ()
            }
          }
        }
        pending = input.next()
      }
      Ok(())
    } catch {
      error => Err(error)
    }
    match drive_result {
      Ok(_) => ()
      Err(error) => {
        if active_stream is Some(stream) {
          stream.fail(error)
        }
        raise error
      }
    }
  })
}

///|
pub async fn[R : @aio.BinaryReader, W : @aio.BinaryWriter, B : @body.Body] serve_http1_connection(
  reader : R,
  writer : W,
  service : async (@types.Request[@body.BodyStream]) -> @types.Response[B],
  config~ : ServerConfig = ServerConfig::defaults(),
) -> Unit {
  run_connection_scope(
    () => {
      config.validate_http1().unwrap_or_error()
      serve_http1_connection_inner(
        Http1RequestInput::new(reader, config),
        writer,
        service,
        config,
      )
    },
    config.close_callback,
  )
}

///|
pub async fn[R : @aio.BinaryReader, W : @aio.BinaryWriter, B : @body.Body] serve_http1_with_error_responder(
  reader : R,
  writer : W,
  service : async (@types.Request[@body.BodyStream]) -> @types.Response[B],
  error_responder : (Error) -> @types.Response[B],
  config~ : ServerConfig = ServerConfig::defaults(),
) -> Unit {
  let mut terminal : Error? = None
  let close_callback = match config.close_callback {
    Some(callback) =>
      Some(fn(error) {
        callback(
          match error {
            Some(_) => error
            None => terminal
          },
        )
      })
    None => None
  }
  run_connection_scope(
    async fn() {
      serve_http1_connection(
        reader,
        writer,
        service,
        config=config.without_close_callback(),
      ) catch {
        error => {
          terminal = Some(error)
          let response = error_responder(error)
          with_outgoing_body_scope(response.body, async fn() {
            let head : @types.Response[Unit] = {
              status: response.status,
              version: Http11,
              headers: response.headers,
              body: (),
            }
            let framing = @http1.BodyFraming::Chunked
            let encoded = match
              @http1.encode_response_head(head, Get, framing) {
              Ok(bytes) => bytes
              Err(codec_error) => raise codec_error
            }
            write_with_timeout(writer, encoded, config.write_timeout_ms)
            write_http1_body(framing, () => response.body.next_frame(), async fn(
              bytes,
              _,
            ) {
              write_with_timeout(writer, bytes, config.write_timeout_ms)
            })
          })
        }
      }
    },
    close_callback,
  )
}
