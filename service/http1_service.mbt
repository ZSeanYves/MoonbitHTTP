///|
pub(all) struct ServerConfig {
  limits : @types.Limits
  read_size : Int
  read_timeout_ms : Int?
  write_timeout_ms : Int?
}

///|
pub fn ServerConfig::defaults() -> ServerConfig {
  {
    limits: @types.Limits::defaults(),
    read_size: 8192,
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
fn should_keep_alive(request : @types.Request[Unit]) -> Bool {
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
pub async fn[R : @aio.Reader, W : @aio.Writer] serve_http1_connection(
  reader : R,
  writer : W,
  service : async (@types.Request[Bytes]) -> @types.Response[Bytes],
  config? : ServerConfig = ServerConfig::defaults(),
) -> Unit {
  let mut head : @types.Request[Unit]? = None
  let body : Array[Byte] = []
  let mut close_after_response = false
  drive_http1_events(
    reader,
    async fn(event) {
      match event {
        RequestHead(request) => {
          close_after_response = !should_keep_alive(request)
          head = Some(request)
          body.clear()
        }
        RequestData(data) => copy_data(body, data)
        RequestTrailers(_) => ()
        RequestEnd => {
          guard head is Some(request_head) else {
            raise @http1.Http1Error::InvalidFraming(
              "body ended without request head",
            )
          }
          let http_method = request_head.http_method
          let version = request_head.version
          let request = request_head.map_body(fn(_) { Bytes::from_array(body) })
          let response = service(request)
          let framing = if @types.response_allows_body(
              http_method,
              response.status,
            ) {
            @http1.BodyFraming::ContentLength(response.body.length())
          } else {
            NoBody
          }
          if close_after_response {
            let name = @types.HeaderName::parse("connection").unwrap()
            let value = @types.HeaderValue::from_string("close").unwrap()
            response.headers.set(name, value)
          }
          let response_head : @types.Response[Unit] = {
            status: response.status,
            version,
            headers: response.headers,
            body: (),
          }
          let encoded_head = match
            @http1.encode_response_head(response_head, http_method, framing) {
            Ok(bytes) => bytes
            Err(error) => raise error
          }
          write_with_timeout(writer, encoded_head, config.write_timeout_ms)
          if framing != NoBody {
            let encoded_body = match
              @http1.encode_body_data(response.body, framing) {
              Ok(bytes) => bytes
              Err(error) => raise error
            }
            write_with_timeout(writer, encoded_body, config.write_timeout_ms)
          }
          head = None
          body.clear()
        }
      }
    },
    config~,
  )
}

///|
pub async fn[R : @aio.Reader, W : @aio.Writer] serve_http1_with_error_responder(
  reader : R,
  writer : W,
  service : async (@types.Request[Bytes]) -> @types.Response[Bytes],
  error_responder : (Error) -> @types.Response[Bytes],
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
      let framing = @http1.BodyFraming::ContentLength(response.body.length())
      let encoded = match @http1.encode_response_head(head, Get, framing) {
        Ok(bytes) => bytes
        Err(codec_error) => raise codec_error
      }
      write_with_timeout(writer, encoded, config.write_timeout_ms)
      write_with_timeout(writer, response.body, config.write_timeout_ms)
    }
  }
}
