///|
priv struct H2PendingRequest {
  http_method : @types.Method
  uri : @types.Uri
  headers : @types.HeaderMap
  body : Array[Byte]
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
  Ok({ http_method: parse_method(meth_text), uri, headers, body: [] })
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
pub async fn[R : @aio.Reader, W : @aio.Writer] serve_http2_connection(
  reader : R,
  writer : W,
  service : async (@types.Request[Bytes]) -> @types.Response[Bytes],
  limits? : @types.Limits = @types.Limits::defaults(),
  upgraded_request? : @types.Request[Bytes]? = None,
  upgrade_settings? : Bytes? = None,
  read_timeout_ms? : Int,
  write_timeout_ms? : Int,
) -> Unit {
  serve_http2_connection_with_timeouts(
    reader,
    writer,
    service,
    limits~,
    upgraded_request~,
    upgrade_settings~,
    read_timeout_ms~,
    write_timeout_ms~,
  )
}

///|
async fn[R : @aio.Reader, W : @aio.Writer] serve_http2_connection_with_timeouts(
  reader : R,
  writer : W,
  service : async (@types.Request[Bytes]) -> @types.Response[Bytes],
  limits? : @types.Limits = @types.Limits::defaults(),
  upgraded_request? : @types.Request[Bytes]? = None,
  upgrade_settings? : Bytes? = None,
  read_timeout_ms~ : Int?,
  write_timeout_ms~ : Int?,
) -> Unit {
  let preface = read_exactly_with_timeout(reader, 24, read_timeout_ms)
  if preface != b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" {
    raise @http2.H2ProtocolError::ConnectionError(
      ProtocolError,
      "invalid HTTP/2 client preface",
    )
  }
  write_with_timeout(
    writer,
    Bytes::from_array(@http2.encode_settings_frame([], false)),
    write_timeout_ms,
  )
  let connection = @http2.H2Connection::new(Server)
  if upgrade_settings is Some(payload) {
    match connection.apply_settings_payload(payload) {
      Ok(_) => ()
      Err(error) => raise error
    }
  }
  let frames = @http2.FrameDecoder::new(max_buffer_size=limits.max_buffer_bytes)
  let decoder = @http2.HpackContext::new(
    max_header_list_size=limits.max_header_bytes,
  )
  let encoder = @http2.HpackContext::new(
    max_header_list_size=limits.max_header_bytes,
  )
  let pending : Map[Int, H2PendingRequest] = Map([])
  let header_block : Array[Byte] = []
  let mut header_stream = 0
  let mut header_end_stream = false
  let write_lock = @async.Mutex::Mutex()
  let mut initial_settings_received = false
  let mut upgrade_dispatched = false
  @async.with_task_group(async fn(group) {
    let reset_stream = async fn(stream_id : Int, code : @http2.H2ErrorCode) {
      pending.remove(stream_id)
      ignore(connection.reset_stream(stream_id))
      let encoded = match @http2.encode_rst_stream(stream_id, code) {
        Ok(value) => value
        Err(error) => raise error
      }
      write_h2_frame(write_lock, writer, encoded, write_timeout_ms)
    }
    let dispatch = fn(stream_id : Int) {
      guard pending.get(stream_id) is Some(value) else { return }
      pending.remove(stream_id)
      let request : @types.Request[Bytes] = {
        http_method: value.http_method,
        uri: value.uri,
        version: Http2,
        headers: value.headers,
        body: Bytes::from_array(value.body),
      }
      group.spawn_bg(async fn() {
        let response = service(request)
        let encoded_headers = match
          @http2.encode_response_headers(
            encoder,
            stream_id,
            response,
            response.body.is_empty(),
          ) {
          Ok(bytes) => bytes
          Err(error) => raise error
        }
        write_h2_frame(write_lock, writer, encoded_headers, write_timeout_ms)
        let mut offset = 0
        while offset < response.body.length() {
          let remaining = response.body.length() - offset
          let requested = remaining.min(@http2.H2_DEFAULT_MAX_FRAME_SIZE)
          let capacity = match
            connection.reserve_send_capacity(stream_id, requested) {
            Ok(value) => value
            Err(error) => raise error
          }
          if capacity == 0 {
            @async.sleep(1)
            continue
          }
          let chunk = response.body[offset:offset + capacity].to_owned()
          let encoded_data = match
            @http2.encode_data_frames(
              stream_id,
              chunk,
              offset + capacity == response.body.length(),
            ) {
            Ok(value) => value
            Err(error) => raise error
          }
          write_h2_frame(write_lock, writer, encoded_data, write_timeout_ms)
          offset += capacity
        }
        match connection.finish_local_stream(stream_id) {
          Ok(_) => ()
          Err(error) => raise error
        }
      })
    }
    if upgraded_request is Some(request) {
      match connection.accept_upgraded_stream1() {
        Ok(_) => ()
        Err(error) => raise error
      }
      pending.set(1, {
        http_method: request.http_method,
        uri: request.uri,
        headers: request.headers,
        body: request.body.to_array(),
      })
    }
    while read_some_with_timeout(reader, 8192, read_timeout_ms) is Some(bytes) {
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
                write_timeout_ms,
              )
            SendPingAck(payload) => {
              let ack = match @http2.encode_ping_ack(payload) {
                Ok(value) => value
                Err(error) => raise error
              }
              write_h2_frame(write_lock, writer, ack, write_timeout_ms)
            }
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
                let request = match decode_h2_request(stream_id, fields) {
                  Ok(value) => value
                  Err(StreamError(error_stream, code, _)) => {
                    reset_stream(error_stream, code)
                    header_stream = 0
                    continue
                  }
                  Err(error) => raise error
                }
                pending.set(stream_id, request)
                if end_stream {
                  dispatch(stream_id)
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
                let request = match decode_h2_request(stream_id, fields) {
                  Ok(value) => value
                  Err(StreamError(error_stream, code, _)) => {
                    reset_stream(error_stream, code)
                    header_stream = 0
                    continue
                  }
                  Err(error) => raise error
                }
                pending.set(stream_id, request)
                if header_end_stream {
                  dispatch(stream_id)
                }
                header_stream = 0
              }
            }
            DataReceived(stream_id, data, end_stream) => {
              guard pending.get(stream_id) is Some(request) else {
                reset_stream(stream_id, ProtocolError)
                continue
              }
              if request.body.length() + data.length() > limits.max_body_bytes {
                reset_stream(stream_id, EnhanceYourCalm)
                continue
              }
              for byte in data {
                request.body.push(byte)
              }
              let updates = match
                connection.release_capacity(stream_id, frame.header.length) {
                Ok(value) => value
                Err(StreamError(error_stream, code, _)) => {
                  reset_stream(error_stream, code)
                  continue
                }
                Err(error) => raise error
              }
              for update in updates {
                if update is SendWindowUpdate(id, amount) {
                  let encoded = match @http2.encode_window_update(id, amount) {
                    Ok(value) => value
                    Err(error) => raise error
                  }
                  write_h2_frame(write_lock, writer, encoded, write_timeout_ms)
                }
              }
              if end_stream {
                dispatch(stream_id)
              }
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
  })
}
