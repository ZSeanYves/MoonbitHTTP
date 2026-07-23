///|
priv struct H2PendingRequest {
  http_method : @types.Method
  uri : @types.Uri
  headers : @types.HeaderMap
  body : @body.BodyStream
  mut body_bytes : Int
  mut dispatched : Bool
  mut handler_done : Bool
}

///|
priv struct H2BlockedData {
  data : Bytes
  end_stream : Bool
}

///|
fn parse_method(value : String) -> @types.Method {
  match value {
    "GET" => Get
    "POST" => Post
    "PUT" => Put
    "DELETE" => Delete
    "HEAD" => Head
    "OPTIONS" => Options
    "PATCH" => Patch
    "TRACE" => Trace
    "CONNECT" => Connect
    other => Extension(other)
  }
}

///|
fn decode_h2_request(
  stream_id : Int,
  fields : Array[@http2.HpackHeader],
  body? : @body.BodyStream = @body.BodyStream::new(),
) -> Result[H2PendingRequest, @http2.H2ProtocolError] {
  let mut meth_text = ""
  let mut path = ""
  let mut scheme = ""
  let mut authority = ""
  let mut saw_method = false
  let mut saw_path = false
  let mut saw_scheme = false
  let mut saw_authority = false
  let mut saw_regular = false
  let headers = @types.HeaderMap::new()
  for field in fields {
    if field.name != field.name.to_lower() {
      return Err(
        StreamError(
          stream_id,
          ProtocolError,
          "HTTP/2 header names must be lowercase",
        ),
      )
    }
    if field.name.has_prefix(":") {
      if saw_regular {
        return Err(
          StreamError(
            stream_id,
            ProtocolError,
            "pseudo-header follows regular header",
          ),
        )
      }
      match field.name {
        ":method" => {
          if saw_method {
            return Err(
              StreamError(stream_id, ProtocolError, "duplicate :method"),
            )
          }
          saw_method = true
          meth_text = field.value
        }
        ":path" => {
          if saw_path {
            return Err(StreamError(stream_id, ProtocolError, "duplicate :path"))
          }
          saw_path = true
          path = field.value
        }
        ":scheme" => {
          if saw_scheme {
            return Err(
              StreamError(stream_id, ProtocolError, "duplicate :scheme"),
            )
          }
          saw_scheme = true
          scheme = field.value
        }
        ":authority" => {
          if saw_authority {
            return Err(
              StreamError(stream_id, ProtocolError, "duplicate :authority"),
            )
          }
          saw_authority = true
          authority = field.value
        }
        _ =>
          return Err(
            StreamError(
              stream_id,
              ProtocolError,
              "unknown request pseudo-header",
            ),
          )
      }
    } else {
      saw_regular = true
      if field.name == "connection" ||
        field.name == "upgrade" ||
        field.name == "keep-alive" ||
        field.name == "transfer-encoding" {
        return Err(
          StreamError(
            stream_id,
            ProtocolError,
            "connection-specific HTTP/2 header",
          ),
        )
      }
      if field.name == "te" && field.value.to_lower() != "trailers" {
        return Err(
          StreamError(
            stream_id,
            ProtocolError,
            "HTTP/2 TE only permits trailers",
          ),
        )
      }
      match headers.append_string(field.name, field.value) {
        Ok(_) => ()
        Err(_) =>
          return Err(
            StreamError(stream_id, ProtocolError, "invalid request header"),
          )
      }
    }
  }
  if !saw_method || meth_text == "" {
    return Err(
      StreamError(stream_id, ProtocolError, "missing required pseudo-header"),
    )
  }
  if meth_text == "CONNECT" {
    if !saw_authority || authority == "" || saw_path || saw_scheme {
      return Err(
        StreamError(stream_id, ProtocolError, "invalid CONNECT pseudo-headers"),
      )
    }
  } else if !saw_path ||
    path == "" ||
    !saw_scheme ||
    scheme == "" ||
    !saw_authority ||
    authority == "" {
    return Err(
      StreamError(
        stream_id,
        ProtocolError,
        "missing required request pseudo-header",
      ),
    )
  }
  let uri = match @types.Uri::parse(if path == "" { "/" } else { path }) {
    Ok(value) => value
    Err(_) => return Err(StreamError(stream_id, ProtocolError, "invalid :path"))
  }
  Ok({
    http_method: parse_method(meth_text),
    uri,
    headers,
    body,
    body_bytes: 0,
    dispatched: false,
    handler_done: false,
  })
}

///|
async fn[W : @aio.Writer] write_h2_frame(
  lock : @async.Mutex,
  writer : W,
  bytes : Bytes,
  timeout_ms : Int?,
) -> Unit {
  lock.acquire()
  defer lock.release()
  write_with_timeout(writer, bytes, timeout_ms)
}

///|
async fn[R : @aio.Reader, W : @aio.Writer, B : @body.Body] serve_http2_connection_inner(
  reader : R,
  writer : W,
  service : async (@types.Request[@body.BodyStream]) -> @types.Response[B],
  config? : ServerConfig = ServerConfig::defaults(),
  upgraded_request? : @types.Request[@body.BodyStream]? = None,
  upgrade_settings? : Bytes? = None,
) -> Unit {
  let preface = read_exactly_with_timeout(reader, 24, config.read_timeout_ms)
  if preface != b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" {
    raise @http2.H2ProtocolError::ConnectionError(
      ProtocolError,
      "invalid HTTP/2 client preface",
    )
  }
  let receive_window = config.body_queue_capacity + 1
  write_with_timeout(
    writer,
    Bytes::from_array(
      @http2.encode_settings_frame([{ id: 4, value: receive_window }], false),
    ),
    config.write_timeout_ms,
  )
  let connection = @http2.H2Connection::new(Server)
  match connection.set_local_initial_window(receive_window) {
    Ok(_) => ()
    Err(error) => raise error
  }
  if receive_window > 65535 {
    let increment = receive_window - 65535
    match connection.increase_connection_receive_window(increment) {
      Ok(_) => ()
      Err(error) => raise error
    }
    write_with_timeout(
      writer,
      @http2.encode_window_update(0, increment).unwrap(),
      config.write_timeout_ms,
    )
  }
  if upgrade_settings is Some(payload) {
    match connection.apply_settings_payload(payload) {
      Ok(_) => ()
      Err(error) => raise error
    }
  }
  let frames = @http2.FrameDecoder::new(
    max_buffer_size=config.limits.max_buffer_bytes,
  )
  let decoder = @http2.HpackContext::new(
    max_header_list_size=config.limits.max_header_bytes,
  )
  let encoder = @http2.HpackContext::new(
    max_header_list_size=config.limits.max_header_bytes,
  )
  let pending : Map[Int, H2PendingRequest] = Map([])
  let blocked : Map[Int, H2BlockedData] = Map([])
  let header_block : Array[Byte] = []
  let mut header_stream = 0
  let mut header_end_stream = false
  let write_lock = @async.Mutex::Mutex()
  let window_signal : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
  let blocked_signal : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
  let mut initial_settings_received = false
  let mut upgrade_dispatched = false
  @async.with_task_group(async fn(group) {
    group.add_defer(fn() {
      let error = @http2.H2ProtocolError::ConnectionError(
        Cancel,
        "HTTP/2 connection task group closed",
      )
      blocked_signal.close(error~)
      for value in pending.values() {
        value.body.fail(error)
      }
    })
    let reset_stream_with_error = async fn(
      stream_id : Int,
      code : @http2.H2ErrorCode,
      failure : Error,
    ) {
      if pending.get(stream_id) is Some(value) {
        value.body.fail(failure)
      }
      pending.remove(stream_id)
      blocked.remove(stream_id)
      ignore(connection.reset_stream(stream_id))
      let encoded = match @http2.encode_rst_stream(stream_id, code) {
        Ok(value) => value
        Err(error) => raise error
      }
      write_h2_frame(write_lock, writer, encoded, config.write_timeout_ms)
    }
    let reset_stream = async fn(stream_id : Int, code : @http2.H2ErrorCode) {
      reset_stream_with_error(
        stream_id,
        code,
        @http2.H2ProtocolError::StreamError(
          stream_id, code, "HTTP/2 stream reset",
        ),
      )
    }
    let send_response = async fn(
      stream_id : Int,
      request : @types.Request[@body.BodyStream],
    ) {
      let response = service(request)
      if pending.get(stream_id) is Some(value) {
        value.handler_done = true
      }
      let exact_zero = response.body.size_hint().exact_size() == Some(0)
      write_lock.acquire()
      let encoded_headers = match
        @http2.encode_response_headers(encoder, stream_id, response, exact_zero) {
        Ok(value) => value
        Err(error) => {
          write_lock.release()
          raise error
        }
      }
      write_with_timeout(writer, encoded_headers, config.write_timeout_ms)
      write_lock.release()
      let mut sent_trailers = false
      while response.body.next_frame() is Some(frame) {
        match frame {
          Data(data) => {
            if sent_trailers {
              raise @http2.H2ProtocolError::StreamError(
                stream_id,
                ProtocolError,
                "response data follows trailers",
              )
            }
            let mut offset = 0
            while offset < data.length() {
              let requested = (data.length() - offset).min(
                @http2.H2_DEFAULT_MAX_FRAME_SIZE,
              )
              let mut capacity = match
                connection.reserve_send_capacity(stream_id, requested) {
                Ok(value) => value
                Err(error) => raise error
              }
              while capacity == 0 {
                window_signal.get()
                capacity = match
                  connection.reserve_send_capacity(stream_id, requested) {
                  Ok(value) => value
                  Err(error) => raise error
                }
              }
              let chunk = data[offset:offset + capacity].to_owned()
              let encoded = match
                @http2.encode_data_frames(stream_id, chunk, false) {
                Ok(value) => value
                Err(error) => raise error
              }
              write_h2_frame(
                write_lock,
                writer,
                encoded,
                config.write_timeout_ms,
              )
              offset += capacity
            }
          }
          Trailers(trailers) => {
            if sent_trailers {
              raise @http2.H2ProtocolError::StreamError(
                stream_id,
                ProtocolError,
                "duplicate response trailers",
              )
            }
            sent_trailers = true
            write_lock.acquire()
            let encoded = match
              @http2.encode_trailers(encoder, stream_id, trailers) {
              Ok(value) => value
              Err(error) => {
                write_lock.release()
                raise error
              }
            }
            write_with_timeout(writer, encoded, config.write_timeout_ms)
            write_lock.release()
          }
        }
      }
      if !sent_trailers && !exact_zero {
        let encoded = match @http2.encode_data_frames(stream_id, b"", true) {
          Ok(value) => value
          Err(error) => raise error
        }
        write_h2_frame(write_lock, writer, encoded, config.write_timeout_ms)
      }
      match connection.finish_local_stream(stream_id) {
        Ok(_) => ()
        Err(error) => raise error
      }
    }
    let dispatch = fn(stream_id : Int) {
      guard pending.get(stream_id) is Some(value) else { return }
      if value.dispatched {
        return
      }
      value.dispatched = true
      let request : @types.Request[@body.BodyStream] = {
        http_method: value.http_method,
        uri: value.uri,
        version: Http2,
        headers: value.headers,
        body: value.body,
      }
      group.spawn_bg(async fn() {
        send_response(stream_id, request) catch {
          error => {
            reset_stream_with_error(stream_id, Cancel, error)
            raise error
          }
        }
      })
    }
    let make_body = fn(stream_id : Int) -> @body.BodyStream {
      @body.BodyStream::new(capacity=config.body_queue_capacity, on_data_consumed=async fn(
        amount,
      ) {
        let updates = match connection.release_capacity(stream_id, amount) {
          Ok(value) => value
          Err(error) => {
            reset_stream_with_error(stream_id, Cancel, error)
            raise error
          }
        }
        for update in updates {
          if update is SendWindowUpdate(id, value) {
            let encoded = match @http2.encode_window_update(id, value) {
              Ok(value) => value
              Err(error) => raise error
            }
            write_h2_frame(write_lock, writer, encoded, config.write_timeout_ms)
          }
        }
        blocked_signal.put(())
      })
    }
    let drain_blocked = fn() {
      for stream_id, value in blocked {
        if pending.get(stream_id) is Some(request) {
          let accepted = request.body.try_push(Data(value.data)) catch {
            error => {
              request.body.fail(error)
              false
            }
          }
          if accepted {
            blocked.remove(stream_id)
            if value.end_stream {
              request.body.finish()
              dispatch(stream_id)
            }
          }
        } else {
          blocked.remove(stream_id)
        }
      }
    }
    group.spawn_bg(
      async fn() {
        while true {
          blocked_signal.get() catch {
            _ => return
          }
          drain_blocked()
        }
      },
      no_wait=true,
      allow_failure=true,
    )
    if upgraded_request is Some(request) {
      match connection.accept_upgraded_stream1() {
        Ok(_) => ()
        Err(error) => raise error
      }
      pending.set(1, {
        http_method: request.http_method,
        uri: request.uri,
        headers: request.headers,
        body: request.body,
        body_bytes: 0,
        dispatched: false,
        handler_done: false,
      })
    }
    while read_some_with_timeout(
            reader,
            config.read_size,
            config.read_timeout_ms,
          )
          is Some(bytes) {
      match frames.feed(bytes) {
        Ok(_) => ()
        Err(error) => raise error
      }
      while true {
        let frame = match frames.next() {
          Ok(Some(value)) => value
          Ok(None) => break
          Err(error) => raise error
        }
        drain_blocked()
        if !initial_settings_received {
          if frame.header.typ != @http2.H2_FRAME_SETTINGS ||
            (frame.header.flags & @http2.H2_FLAGS_ACK) != 0 {
            raise @http2.H2ProtocolError::ConnectionError(
              ProtocolError,
              "client preface is not followed by SETTINGS",
            )
          }
          initial_settings_received = true
        }
        let actions = match connection.receive(frame) {
          Ok(value) => value
          Err(StreamError(stream_id, code, _)) => {
            reset_stream(stream_id, code)
            []
          }
          Err(error) => raise error
        }
        for action in actions {
          match action {
            SendSettingsAck =>
              write_h2_frame(
                write_lock,
                writer,
                Bytes::from_array(@http2.encode_settings_frame([], true)),
                config.write_timeout_ms,
              )
            SendPingAck(payload) => {
              let ack = match @http2.encode_ping_ack(payload) {
                Ok(value) => value
                Err(error) => raise error
              }
              write_h2_frame(write_lock, writer, ack, config.write_timeout_ms)
            }
            WindowAvailable(_, _) => window_signal.put(())
            HeadersStarted(stream_id, end_stream) => {
              header_stream = stream_id
              header_end_stream = end_stream
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
                  decoder.decode(Bytes::from_array(header_block)) {
                  Ok(value) => value
                  Err(error) => raise error
                }
                if pending.get(stream_id) is Some(request) {
                  let trailers = @types.HeaderMap::new()
                  for field in fields {
                    if field.name.has_prefix(":") {
                      raise @http2.H2ProtocolError::StreamError(
                        stream_id,
                        ProtocolError,
                        "pseudo-header in request trailers",
                      )
                    }
                    match trailers.append_string(field.name, field.value) {
                      Ok(_) => ()
                      Err(_) =>
                        raise @http2.H2ProtocolError::StreamError(
                          stream_id,
                          ProtocolError,
                          "invalid request trailer",
                        )
                    }
                  }
                  request.body.push(Trailers(trailers))
                  request.body.finish()
                  dispatch(stream_id)
                } else {
                  let body = make_body(stream_id)
                  let request = match
                    decode_h2_request(stream_id, fields, body~) {
                    Ok(value) => value
                    Err(StreamError(error_stream, code, _)) => {
                      reset_stream(error_stream, code)
                      header_stream = 0
                      continue
                    }
                    Err(error) => raise error
                  }
                  pending.set(stream_id, request)
                  dispatch(stream_id)
                  if end_stream {
                    if pending.get(stream_id) is Some(value) {
                      value.body.finish()
                    }
                  }
                }
                header_stream = 0
              }
            }
            HeadersContinued(stream_id, end_headers) => {
              if stream_id != header_stream {
                raise @http2.H2ProtocolError::ConnectionError(
                  ProtocolError,
                  "CONTINUATION stream changed",
                )
              }
              for byte in frame.payload {
                header_block.push(byte)
              }
              if end_headers {
                let fields = match
                  decoder.decode(Bytes::from_array(header_block)) {
                  Ok(value) => value
                  Err(error) => raise error
                }
                let body = make_body(stream_id)
                let request = match
                  decode_h2_request(stream_id, fields, body~) {
                  Ok(value) => value
                  Err(error) => raise error
                }
                pending.set(stream_id, request)
                dispatch(stream_id)
                if header_end_stream {
                  if pending.get(stream_id) is Some(value) {
                    value.body.finish()
                  }
                }
                header_stream = 0
              }
            }
            DataReceived(stream_id, data, end_stream, flow_size) => {
              guard pending.get(stream_id) is Some(request) else {
                reset_stream(stream_id, ProtocolError)
                continue
              }
              if request.body_bytes + data.length() >
                config.limits.max_body_bytes {
                reset_stream(stream_id, EnhanceYourCalm)
                continue
              }
              request.body_bytes += data.length()
              if request.handler_done {
                let updates = match
                  connection.release_capacity(stream_id, flow_size) {
                  Ok(value) => value
                  Err(error) => raise error
                }
                for update in updates {
                  if update is SendWindowUpdate(id, amount) {
                    let encoded = match
                      @http2.encode_window_update(id, amount) {
                      Ok(value) => value
                      Err(error) => raise error
                    }
                    write_h2_frame(
                      write_lock,
                      writer,
                      encoded,
                      config.write_timeout_ms,
                    )
                  }
                }
                if end_stream {
                  request.body.finish()
                }
                continue
              }
              if flow_size > data.length() {
                let updates = match
                  connection.release_capacity(
                    stream_id,
                    flow_size - data.length(),
                  ) {
                  Ok(value) => value
                  Err(error) => raise error
                }
                for update in updates {
                  if update is SendWindowUpdate(id, amount) {
                    write_h2_frame(
                      write_lock,
                      writer,
                      @http2.encode_window_update(id, amount).unwrap(),
                      config.write_timeout_ms,
                    )
                  }
                }
              }
              let data = Bytes::from_array(data)
              let accepted = request.body.try_push(Data(data))
              if !accepted {
                if blocked.get(stream_id) is Some(_) {
                  reset_stream(stream_id, EnhanceYourCalm)
                } else {
                  blocked.set(stream_id, { data, end_stream })
                }
              } else if end_stream {
                request.body.finish()
                dispatch(stream_id)
              }
            }
            StreamResetReceived(stream_id, _) =>
              if pending.get(stream_id) is Some(request) {
                request.body.fail(
                  @http2.H2ProtocolError::StreamError(
                    stream_id,
                    Cancel,
                    "peer reset stream",
                  ),
                )
                pending.remove(stream_id)
              }
            _ => ()
          }
        }
        if initial_settings_received &&
          upgraded_request is Some(_) &&
          !upgrade_dispatched {
          upgrade_dispatched = true
          dispatch(1)
        }
      }
    }
    for value in pending.values() {
      value.body.fail(
        @http2.H2ProtocolError::ConnectionError(
          ProtocolError,
          "HTTP/2 peer closed connection",
        ),
      )
    }
  })
}

///|
pub async fn[R : @aio.Reader, W : @aio.Writer, B : @body.Body] serve_http2_connection(
  reader : R,
  writer : W,
  service : async (@types.Request[@body.BodyStream]) -> @types.Response[B],
  config? : ServerConfig = ServerConfig::defaults(),
  upgraded_request? : @types.Request[@body.BodyStream]? = None,
  upgrade_settings? : Bytes? = None,
) -> Unit {
  serve_http2_connection_inner(
    reader,
    writer,
    service,
    config~,
    upgraded_request~,
    upgrade_settings~,
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
