///|
pub async fn[R : @aio.Reader, W : @aio.Writer] serve_http1_or_h2c_connection(
  reader : R,
  writer : W,
  service : async (@types.Request[Bytes]) -> @types.Response[Bytes],
  config? : ServerConfig = ServerConfig::defaults(),
) -> Unit {
  let decoder = @http1.RequestDecoder::new(limits=config.limits)
  let mut head : @types.Request[Unit]? = None
  let body : Array[Byte] = []
  while read_some_with_timeout(reader, config.read_size, config.read_timeout_ms)
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
        RequestHead(value) => {
          head = Some(value)
          body.clear()
        }
        RequestData(value) => copy_data(body, value)
        RequestTrailers(_) => ()
        RequestEnd => {
          guard head is Some(request_head) else {
            raise @http1.Http1Error::InvalidFraming(
              "request ended without a head",
            )
          }
          let request = request_head.map_body(fn(_) { Bytes::from_array(body) })
          if @auto.detect_h2c_upgrade(request.headers) {
            let settings_values = request.headers.get_all_string(
              "http2-settings",
            )
            if settings_values.length() != 1 {
              raise @http1.Http1Error::InvalidHeader(
                "h2c requires exactly one HTTP2-Settings field",
              )
            }
            let settings = @base64.decode(
              settings_values[0].to_string_lossy(),
              url_safe=true,
            ) catch {
              _ =>
                raise @http1.Http1Error::InvalidHeader(
                  "invalid base64url HTTP2-Settings",
                )
            }
            write_with_timeout(
              writer,
              b"HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: h2c\r\n\r\n",
              config.write_timeout_ms,
            )
            let buffered = decoder.take_buffered()
            let replay = @aio.MemoryReader(async fn(replay_writer) {
              replay_writer.write(buffered)
              replay_writer.write_reader(reader)
            })
            let upgraded_headers = request.headers
            for name_text in ["connection", "upgrade", "http2-settings"] {
              let name = @types.HeaderName::parse(name_text).unwrap()
              upgraded_headers.remove(name)
            }
            let upgraded : @types.Request[Bytes] = {
              http_method: request.http_method,
              uri: request.uri,
              version: Http2,
              headers: upgraded_headers,
              body: request.body,
            }
            serve_http2_connection_with_timeouts(
              replay,
              writer,
              service,
              limits=config.limits,
              upgraded_request=Some(upgraded),
              upgrade_settings=Some(settings),
              read_timeout_ms=config.read_timeout_ms,
              write_timeout_ms=config.write_timeout_ms,
            )
            return
          }
          let response = service(request)
          let close = !should_keep_alive(request_head)
          if close {
            response.headers.set(
              @types.HeaderName::parse("connection").unwrap(),
              @types.HeaderValue::from_string("close").unwrap(),
            )
          }
          let framing = if @types.response_allows_body(
              request_head.http_method,
              response.status,
            ) {
            @http1.BodyFraming::ContentLength(response.body.length())
          } else {
            NoBody
          }
          let response_head : @types.Response[Unit] = {
            status: response.status,
            version: request_head.version,
            headers: response.headers,
            body: (),
          }
          let encoded_head = match
            @http1.encode_response_head(
              response_head,
              request_head.http_method,
              framing,
            ) {
            Ok(value) => value
            Err(error) => raise error
          }
          write_with_timeout(writer, encoded_head, config.write_timeout_ms)
          if framing != NoBody {
            write_with_timeout(writer, response.body, config.write_timeout_ms)
          }
          head = None
          body.clear()
          if close {
            return
          }
        }
      }
    }
  }
  decoder.finish_input()
  match decoder.next() {
    Err(error) => raise error
    _ => ()
  }
}
