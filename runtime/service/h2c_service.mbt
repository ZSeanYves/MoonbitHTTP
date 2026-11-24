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
fn strip_h2c_connection_headers(headers : @types.HeaderMap) -> Unit raise {
  for name_text in ["connection", "upgrade", "http2-settings"] {
    let name = match @types.HeaderName::parse(name_text) {
      Ok(value) => value
      Err(error) => raise error
    }
    headers.remove(name)
  }
}

///|
async fn[R : @aio.BinaryReader, W : @aio.BinaryWriter, B : @body.Body] serve_http1_or_h2c_connection_inner(
  reader : R,
  writer : W,
  service : async (@types.Request[@body.BodyStream]) -> @types.Response[B],
  config~ : ServerConfig = ServerConfig::defaults(),
  shutdown~ : ServerShutdown? = None,
) -> Unit {
  config.validate().unwrap_or_error()
  let input = Http1RequestInput::new(reader, config)
  let head = match input.next() {
    Some(RequestHead(head)) => head
    None => return
    _ =>
      raise @http1.Http1Error::InvalidFraming(
        "request body before request head",
      )
  }
  if !@detection.is_h2c_upgrade(head.headers) {
    serve_http1_connection_inner(
      input,
      writer,
      service,
      config,
      first_head=Some(head),
    )
    return
  }

  let settings = decode_h2c_settings(head.headers)
  guard accept_http1_expectation(head, writer, config.write_timeout_ms) else {
    return ()
  }
  strip_h2c_connection_headers(head.headers)
  let body = match @body.BodyStream::new(capacity=config.body_queue_capacity) {
    Ok(value) => value
    Err(error) => raise error
  }
  let upgraded : @types.Request[@body.BodyStream] = {
    http_method: head.http_method,
    uri: head.uri,
    version: Http2,
    headers: head.headers,
    body,
  }
  let responses : @aqueue.Queue[@types.Response[B]] = Queue(kind=Blocking(1))
  let mut staged_response : @types.Response[B]? = None
  let mut handler_done = false
  let upgrade_result : Result[Unit, Error] = try {
    @async.with_task_group(async fn(group) {
      group.add_defer(fn() {
        // The H2 callback is the ownership handoff. Failures in request drain,
        // the switching response, or the H2 preface must release a staged body.
        if staged_response is Some(response) {
          response.body.cancel(@body.BodyError::Cancelled)
          staged_response = None
        }
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
        staged_response = Some(response)
        handler_done = true
        // Upgrade already stops delivering new input when the handler returns.
        // Retain its queued frames for a lazy response, but wake blocked pushes.
        body.finish()
        responses.put(response)
      })

      for ;; {
        let read : Result[@http1.RequestEvent?, Error] = Ok(input.next()) catch {
          error => Err(error)
        }
        let event = match read {
          Ok(value) => value
          Err(error) => {
            body.fail(error)
            raise error
          }
        }
        match event {
          Some(RequestData(data)) =>
            if !handler_done {
              body.push(Data(data)) catch {
                _ if handler_done => ()
                error => raise error
              }
            }
          Some(RequestTrailers(trailers)) =>
            if !handler_done {
              body.push(Trailers(trailers)) catch {
                _ if handler_done => ()
                error => raise error
              }
            }
          Some(RequestEnd) => {
            body.finish()
            break
          }
          Some(RequestHead(_)) =>
            raise @http1.Http1Error::InvalidFraming(
              "request head during h2c upgrade body",
            )
          None =>
            raise @http1.Http1Error::UnexpectedEof("h2c upgrade request body")
        }
      }

      write_with_timeout(
        writer,
        b"HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: h2c\r\n\r\n",
        config.write_timeout_ms,
      )
      let buffered = input.decoder.take_buffered()
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
            let response = responses.get()
            staged_response = None
            response
          } else {
            service(request)
          }
        },
        config=config.without_close_callback(),
        shutdown~,
        upgraded_request=Some(upgraded),
        upgrade_settings=Some(settings),
      ) catch {
        @http2.H2ProtocolError::ConnectionError(
          ProtocolError,
          "HTTP/2 peer closed before initial SETTINGS",
        ) => {
          // Fail the outer h2c request body before the upgrade task group
          // joins its application handler. This wakes a handler blocked on
          // body consumption when the peer closes before initial SETTINGS.
          let error = @http2.H2ProtocolError::ConnectionError(
            ProtocolError,
            "HTTP/2 peer closed before initial SETTINGS",
          )
          body.fail(error)
          raise error
        }
        error => raise error
      }
    })
    Ok(())
  } catch {
    error => Err(error)
  }
  match upgrade_result {
    Ok(_) => ()
    Err(error) => {
      body.fail(error)
      raise error
    }
  }
}

///|
pub async fn[R : @aio.BinaryReader, W : @aio.BinaryWriter, B : @body.Body] serve_http1_or_h2c_connection(
  reader : R,
  writer : W,
  service : async (@types.Request[@body.BodyStream]) -> @types.Response[B],
  config~ : ServerConfig = ServerConfig::defaults(),
  shutdown~ : ServerShutdown? = None,
) -> Unit {
  run_connection_scope(
    () => {
      serve_http1_or_h2c_connection_inner(
        reader,
        writer,
        service,
        config=config.without_close_callback(),
        shutdown~,
      )
    },
    config.close_callback,
  )
}
