///|
pub(all) struct ServerConfig {
  limits : @types.Limits
  read_size : Int
  body_queue_capacity : Int
  read_timeout_ms : Int?
  write_timeout_ms : Int?
}

///|
pub fn ServerConfig::defaults() -> ServerConfig {
  {
    limits: @types.Limits::defaults(),
    read_size: 8192,
    body_queue_capacity: 8,
    read_timeout_ms: None,
    write_timeout_ms: None,
  }
}

///|
async fn[R : @aio.Reader] read_some_with_timeout(
  reader : R,
  max_len : Int,
  timeout_ms : Int?,
) -> Bytes? {
  match timeout_ms {
    Some(timeout) if timeout > 0 =>
      @async.with_timeout(timeout, () => reader.read_some(max_len~))
    _ => reader.read_some(max_len~)
  }
}

///|
async fn[R : @aio.Reader] read_exactly_with_timeout(
  reader : R,
  len : Int,
  timeout_ms : Int?,
) -> Bytes {
  match timeout_ms {
    Some(timeout) if timeout > 0 =>
      @async.with_timeout(timeout, () => reader.read_exactly(len))
    _ => reader.read_exactly(len)
  }
}

///|
async fn[W : @aio.Writer] write_with_timeout(
  writer : W,
  bytes : Bytes,
  timeout_ms : Int?,
) -> Unit {
  match timeout_ms {
    Some(timeout) if timeout > 0 =>
      @async.with_timeout(timeout, () => writer.write(bytes))
    _ => writer.write(bytes)
  }
}

///|
fn copy_data(target : Array[Byte], source : BytesView) -> Unit {
  for byte in source {
    target.push(byte)
  }
}

///|
fn header_has_token(
  headers : @types.HeaderMap,
  name : String,
  token : String,
) -> Bool {
  for value in headers.get_all_string(name) {
    for part in value.to_string_lossy().split(",") {
      if part.trim().to_lower() == token {
        return true
      }
    }
  }
  false
}

///|
fn[A] should_keep_alive(request : @types.Request[A]) -> Bool {
  match request.version {
    Http11 => !header_has_token(request.headers, "connection", "close")
    Http10 => header_has_token(request.headers, "connection", "keep-alive")
    Http2 => true
  }
}

///|
pub async fn[R : @aio.Reader] drive_http1_events(
  reader : R,
  on_event : async (@http1.RequestEvent) -> Unit,
  config? : ServerConfig = ServerConfig::defaults(),
) -> Unit {
  let decoder = @http1.RequestDecoder::new(limits=config.limits)
  while read_some_with_timeout(reader, config.read_size, config.read_timeout_ms)
        is Some(bytes) {
    match decoder.feed(bytes) {
      Ok(_) => ()
      Err(error) => raise error
    }
    while true {
      match decoder.next() {
        Err(error) => raise error
        Ok(None) => break
        Ok(Some(event)) => on_event(event)
      }
    }
  }
  decoder.finish_input()
  while true {
    match decoder.next() {
      Err(error) => raise error
      Ok(None) => break
      Ok(Some(event)) => on_event(event)
    }
  }
}

///|
pub async fn[R : @aio.Reader, W : @aio.Writer, B : @body.Body] serve_http1_connection(
  reader : R,
  writer : W,
  service : async (@types.Request[@body.BodyStream]) -> @types.Response[B],
  config? : ServerConfig = ServerConfig::defaults(),
) -> Unit {
  let mut active : @async.Task[Unit]? = None
  let mut active_stream : @body.BodyStream? = None
  let mut handler_done = false
  @async.with_task_group(async fn(group) {
    let finish_handler = fn() {
      if active_stream is Some(stream) {
        stream.finish()
      }
    }
    let decoder = @http1.RequestDecoder::new(limits=config.limits)
    while read_some_with_timeout(
            reader,
            config.read_size,
            config.read_timeout_ms,
          )
          is Some(bytes) {
      match decoder.feed(bytes) {
        Ok(_) => ()
        Err(error) => raise error
      }
      while true {
        let event = match decoder.next() {
          Ok(Some(value)) => value
          Ok(None) => break
          Err(error) => raise error
        }
        match event {
          RequestHead(request) => {
            handler_done = false
            let stream = @body.BodyStream::new(
              capacity=config.body_queue_capacity,
            )
            active_stream = Some(stream)
            let request = request.map_body(fn(_) { stream })
            active = Some(
              group.spawn(async fn() {
                defer {
                  handler_done = true
                }
                let response = service(request)
                let request_method = request.http_method
                let version = request.version
                let mut framing = @http1.NoBody
                if @types.response_allows_body(request_method, response.status) {
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
                if !should_keep_alive(request) || framing == CloseDelimited {
                  response.headers.set(
                    @types.HeaderName::parse("connection").unwrap(),
                    @types.HeaderValue::from_string("close").unwrap(),
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
                let mut remaining : Int? = match framing {
                  ContentLength(size) => Some(size)
                  _ => None
                }
                let mut sent_trailers = false
                while response.body.next_frame() is Some(frame) {
                  match frame {
                    Data(data) => {
                      if sent_trailers {
                        raise @http1.Http1Error::InvalidFraming(
                          "response data follows trailers",
                        )
                      }
                      match remaining {
                        Some(value) => {
                          if data.length() > value {
                            raise @http1.InvalidFraming(
                              "response body exceeds content-length",
                            )
                          }
                          remaining = Some(value - data.length())
                        }
                        None => ()
                      }
                      let encoded = match
                        @http1.encode_body_data(data, framing) {
                        Ok(value) => value
                        Err(error) => raise error
                      }
                      write_with_timeout(
                        writer,
                        encoded,
                        config.write_timeout_ms,
                      )
                    }
                    Trailers(trailers) => {
                      if sent_trailers {
                        raise @http1.Http1Error::InvalidFraming(
                          "duplicate response trailers",
                        )
                      }
                      sent_trailers = true
                      let encoded = match
                        @http1.encode_body_end(framing, trailers~) {
                        Ok(value) => value
                        Err(error) => raise error
                      }
                      write_with_timeout(
                        writer,
                        encoded,
                        config.write_timeout_ms,
                      )
                    }
                  }
                }
                if remaining is Some(value) && value != 0 {
                  raise @http1.InvalidFraming(
                    "response body shorter than content-length",
                  )
                }
                if framing == Chunked && !sent_trailers {
                  let encoded = match @http1.encode_body_end(framing) {
                    Ok(value) => value
                    Err(error) => raise error
                  }
                  write_with_timeout(writer, encoded, config.write_timeout_ms)
                }
              }),
            )
          }
          RequestData(data) =>
            if !handler_done && active_stream is Some(stream) {
              stream.push(Data(data))
            }
          RequestTrailers(trailers) =>
            if !handler_done && active_stream is Some(stream) {
              stream.push(Trailers(trailers))
            }
          RequestEnd => {
            finish_handler()
            guard active is Some(task) else {
              raise @http1.InvalidFraming("request ended without request head")
            }
            task.wait()
            active = None
            active_stream = None
          }
        }
      }
    }
    decoder.finish_input()
    while true {
      match decoder.next() {
        Err(error) => raise error
        Ok(None) => break
        Ok(Some(RequestData(data))) =>
          if !handler_done && active_stream is Some(stream) {
            stream.push(Data(data))
          }
        Ok(Some(RequestTrailers(trailers))) =>
          if !handler_done && active_stream is Some(stream) {
            stream.push(Trailers(trailers))
          }
        Ok(Some(RequestEnd)) => {
          finish_handler()
          guard active is Some(task) else {
            raise @http1.Http1Error::InvalidFraming(
              "request ended without request head",
            )
          }
          task.wait()
          active = None
          active_stream = None
        }
        Ok(Some(RequestHead(_))) =>
          raise @http1.Http1Error::UnexpectedEof("request body")
      }
    }
  })
}

///|
pub async fn[R : @aio.Reader, W : @aio.Writer, B : @body.Body] serve_http1_with_error_responder(
  reader : R,
  writer : W,
  service : async (@types.Request[@body.BodyStream]) -> @types.Response[B],
  error_responder : (Error) -> @types.Response[B],
  config? : ServerConfig = ServerConfig::defaults(),
) -> Unit {
  serve_http1_connection(reader, writer, service, config~) catch {
    error => {
      let response = error_responder(error)
      let head : @types.Response[Unit] = {
        status: response.status,
        version: Http11,
        headers: response.headers,
        body: (),
      }
      let framing = @http1.BodyFraming::Chunked
      let encoded = match @http1.encode_response_head(head, Get, framing) {
        Ok(bytes) => bytes
        Err(codec_error) => raise codec_error
      }
      write_with_timeout(writer, encoded, config.write_timeout_ms)
      while response.body.next_frame() is Some(frame) {
        match frame {
          Data(data) => {
            let encoded = match @http1.encode_body_data(data, framing) {
              Ok(value) => value
              Err(codec_error) => raise codec_error
            }
            write_with_timeout(writer, encoded, config.write_timeout_ms)
          }
          Trailers(trailers) => {
            let encoded = match @http1.encode_body_end(framing, trailers~) {
              Ok(value) => value
              Err(codec_error) => raise codec_error
            }
            write_with_timeout(writer, encoded, config.write_timeout_ms)
          }
        }
      }
      write_with_timeout(
        writer,
        @http1.encode_body_end(framing).unwrap(),
        config.write_timeout_ms,
      )
    }
  }
}
