///|
fn decode_h2c_settings(
  headers : @types.HeaderMap,
) -> Bytes raise @http1.Http1Error {
  let values = headers.get_all_string("http2-settings")
  if values.length() != 1 {
    raise InvalidHeader("h2c requires exactly one HTTP2-Settings field")
  }
  @base64.decode(values[0].to_string_lossy(), url_safe=true) catch {
    _ => raise InvalidHeader("invalid base64url HTTP2-Settings")
  }
}

///|
fn strip_h2c_connection_headers(headers : @types.HeaderMap) -> Unit {
  for name_text in ["connection", "upgrade", "http2-settings"] {
    headers.remove(@types.HeaderName::parse(name_text).unwrap())
  }
}

///|
async fn[R : @aio.Reader, W : @aio.Writer, B : @body.Body] serve_http1_or_h2c_connection_inner(
  reader : R,
  writer : W,
  service : async (@types.Request[@body.BodyStream]) -> @types.Response[B],
  config? : ServerConfig = ServerConfig::defaults(),
) -> Unit {
  let decoder = @http1.RequestDecoder::new(limits=config.limits)
  let prefix : Array[Byte] = []
  let mut request_head : @types.Request[Unit]? = None
  while request_head is None {
    let bytes = match
      read_some_with_timeout(reader, config.read_size, config.read_timeout_ms) {
      Some(value) => value
      None => {
        decoder.finish_input()
        match decoder.next() {
          Err(error) => raise error
          _ => return
        }
      }
    }
    copy_data(prefix, bytes)
    match decoder.feed(bytes) {
      Ok(_) => ()
      Err(error) => raise error
    }
    while request_head is None {
      match decoder.next() {
        Ok(Some(RequestHead(value))) => request_head = Some(value)
        Ok(Some(_)) =>
          raise @http1.Http1Error::InvalidFraming(
            "request body arrived before request head",
          )
        Ok(None) => break
        Err(error) => raise error
      }
    }
  }
  guard request_head is Some(head) else { return }
  if !@auto.detect_h2c_upgrade(head.headers) {
    let replay = @aio.MemoryReader(async fn(replay_writer) {
      replay_writer.write(Bytes::from_array(prefix))
      replay_writer.write_reader(reader)
    })
    serve_http1_connection(replay, writer, service, config~)
    return
  }

  let settings = decode_h2c_settings(head.headers)
  strip_h2c_connection_headers(head.headers)
  let body = @body.BodyStream::new(capacity=config.body_queue_capacity)
  let upgraded : @types.Request[@body.BodyStream] = {
    http_method: head.http_method,
    uri: head.uri,
    version: Http2,
    headers: head.headers,
    body,
  }
  let responses : @aqueue.Queue[@types.Response[B]] = Queue(kind=Blocking(1))
  let mut handler_done = false
  @async.with_task_group(async fn(group) {
    group.add_defer(fn() {
      if !handler_done {
        body.fail(
          @http2.H2ProtocolError::ConnectionError(
            Cancel,
            "h2c upgrade scope closed",
          ),
        )
      }
    })
    group.spawn_bg(async fn() {
      let response = service(upgraded)
      handler_done = true
      responses.put(response)
    })

    let mut request_ended = false
    while !request_ended {
      while true {
        let event = match decoder.next() {
          Ok(Some(value)) => value
          Ok(None) => break
          Err(error) => {
            body.fail(error)
            raise error
          }
        }
        match event {
          RequestHead(_) =>
            raise @http1.Http1Error::InvalidFraming(
              "pipelined request before h2c upgrade completed",
            )
          RequestData(data) => if !handler_done { body.push(Data(data)) }
          RequestTrailers(trailers) =>
            if !handler_done {
              body.push(Trailers(trailers))
            }
          RequestEnd => {
            body.finish()
            request_ended = true
            break
          }
        }
      }
      if request_ended {
        break
      }
      match
        read_some_with_timeout(reader, config.read_size, config.read_timeout_ms) {
        Some(bytes) =>
          match decoder.feed(bytes) {
            Ok(_) => ()
            Err(error) => {
              body.fail(error)
              raise error
            }
          }
        None => {
          decoder.finish_input()
          match decoder.next() {
            Err(error) => {
              body.fail(error)
              raise error
            }
            _ =>
              raise @http1.Http1Error::UnexpectedEof("h2c upgrade request body")
          }
        }
      }
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
    let mut stream1 = true
    serve_http2_connection(
      replay,
      writer,
      async fn(request) {
        if stream1 {
          stream1 = false
          responses.get()
        } else {
          service(request)
        }
      },
      config=config.without_close_callback(),
      upgraded_request=Some(upgraded),
      upgrade_settings=Some(settings),
    )
  }) catch {
    error => {
      body.fail(error)
      raise error
    }
  }
}

///|
pub async fn[R : @aio.Reader, W : @aio.Writer, B : @body.Body] serve_http1_or_h2c_connection(
  reader : R,
  writer : W,
  service : async (@types.Request[@body.BodyStream]) -> @types.Response[B],
  config? : ServerConfig = ServerConfig::defaults(),
) -> Unit {
  serve_http1_or_h2c_connection_inner(
    reader,
    writer,
    service,
    config=config.without_close_callback(),
  ) catch {
    error => {
      if config.close_callback is Some(callback) {
        callback(Some(error))
      }
      raise error
    }
  }
  if config.close_callback is Some(callback) {
    callback(None)
  }
}
