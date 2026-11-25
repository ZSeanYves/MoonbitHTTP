///|
priv struct H2PendingRequest {
  http_method : @types.Method
  uri : @types.Uri
  headers : @types.HeaderMap
  body : @body.BodyStream
  credit : H2ReceiveCredit
  mut body_bytes : Int32
  expected_body_bytes : Int32?
  mut dispatched : Bool
  mut response_finished : Bool
  mut request_ended : Bool
}

///|
priv enum H2ServerBlockedFrame {
  BlockedData(Bytes, Bool)
  BlockedTrailers(@types.HeaderMap)
}

///|
priv struct H2HandlerTask {
  mut task : @async.Task[Unit]?
}

///|
fn H2PendingRequest::has_expected_length(self : H2PendingRequest) -> Bool {
  match self.expected_body_bytes {
    Some(value) => value == self.body_bytes
    None => true
  }
}

///|
fn decode_h2_request(
  stream_id : Int32,
  fields : Array[@http2.HpackHeader],
  body~ : @body.BodyStream = @body.BodyStream::new().unwrap(),
  credit~ : H2ReceiveCredit = H2ReceiveCredit::new(),
) -> Result[H2PendingRequest, @http2.H2ProtocolError] {
  let mut meth_text = ""
  let mut path = ""
  let mut scheme = ""
  let mut authority = ""
  let mut saw_method = false
  let mut saw_path = false
  let mut saw_scheme = false
  let mut saw_authority = false
  let mut regular_host : @types.Authority? = None
  let mut saw_regular = false
  let headers = @types.HeaderMap::new()
  for field in fields {
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
          meth_text = match h2_field_text(field.value) {
            Some(value) => value
            None =>
              return Err(
                StreamError(stream_id, ProtocolError, "invalid :method"),
              )
          }
        }
        ":path" => {
          if saw_path {
            return Err(StreamError(stream_id, ProtocolError, "duplicate :path"))
          }
          saw_path = true
          path = match h2_field_text(field.value) {
            Some(value) => value
            None =>
              return Err(StreamError(stream_id, ProtocolError, "invalid :path"))
          }
        }
        ":scheme" => {
          if saw_scheme {
            return Err(
              StreamError(stream_id, ProtocolError, "duplicate :scheme"),
            )
          }
          saw_scheme = true
          scheme = match h2_field_text(field.value) {
            Some(value) => value
            None =>
              return Err(
                StreamError(stream_id, ProtocolError, "invalid :scheme"),
              )
          }
        }
        ":authority" => {
          if saw_authority {
            return Err(
              StreamError(stream_id, ProtocolError, "duplicate :authority"),
            )
          }
          saw_authority = true
          authority = match h2_field_text(field.value) {
            Some(value) => value
            None =>
              return Err(
                StreamError(stream_id, ProtocolError, "invalid :authority"),
              )
          }
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
      if !@http_fields.Request.allows(field.name, field.value) {
        return Err(
          StreamError(
            stream_id,
            ProtocolError,
            "forbidden HTTP/2 request field",
          ),
        )
      }
      if field.name == "host" {
        if regular_host is Some(_) {
          return Err(StreamError(stream_id, ProtocolError, "duplicate Host"))
        }
        let text = match h2_field_text(field.value) {
          Some(value) => value
          None =>
            return Err(StreamError(stream_id, ProtocolError, "invalid Host"))
        }
        regular_host = match @types.Authority::parse_endpoint(text) {
          Ok(value) => Some(value)
          Err(_) =>
            return Err(StreamError(stream_id, ProtocolError, "invalid Host"))
        }
        continue
      }
      if !append_regular_header(headers, field.name, field.value) {
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
  let parsed_authority = match @types.Authority::parse_endpoint(authority) {
    Ok(value) => value
    Err(_) =>
      return Err(StreamError(stream_id, ProtocolError, "invalid :authority"))
  }
  if regular_host is Some(host) &&
    (
      host.host != parsed_authority.host ||
      host.port != parsed_authority.port ||
      host.ip_literal != parsed_authority.ip_literal
    ) {
    return Err(
      StreamError(stream_id, ProtocolError, "Host/:authority mismatch"),
    )
  }
  if meth_text != "CONNECT" && scheme != "http" && scheme != "https" {
    return Err(StreamError(stream_id, ProtocolError, "invalid :scheme"))
  }
  let http_method = match @types.Method::parse(meth_text) {
    Ok(value) => value
    Err(_) =>
      return Err(StreamError(stream_id, ProtocolError, "invalid :method"))
  }
  let uri = if http_method == Connect {
    match @types.Uri::parse_request_target(authority, http_method) {
      Ok(value) => value
      Err(_) =>
        return Err(StreamError(stream_id, ProtocolError, "invalid :authority"))
    }
  } else {
    match @types.Uri::parse_request_target(path, http_method) {
      Ok(value) if value.form == OriginForm || value.form == AsteriskForm =>
        value
      Err(_) =>
        return Err(StreamError(stream_id, ProtocolError, "invalid :path"))
      _ => return Err(StreamError(stream_id, ProtocolError, "invalid :path"))
    }
  }
  match headers.append_string("host", authority) {
    Ok(_) => ()
    Err(_) =>
      return Err(StreamError(stream_id, ProtocolError, "invalid :authority"))
  }
  join_request_cookies(headers)
  let expected_body_bytes = match headers.body_content_length() {
    Ok(value) => value
    Err(_) =>
      return Err(
        StreamError(stream_id, ProtocolError, "invalid content-length"),
      )
  }
  Ok({
    http_method,
    uri,
    headers,
    body,
    credit,
    body_bytes: 0,
    expected_body_bytes,
    dispatched: false,
    response_finished: false,
    request_ended: false,
  })
}
