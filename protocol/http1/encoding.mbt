///|
fn push_bytes(out : Array[Byte], bytes : BytesView) -> Unit {
  for byte in bytes {
    out.push(byte)
  }
}

///|
fn push_text(out : Array[Byte], text : String) -> Unit {
  push_bytes(out, @utf8.encode(text))
}

///|
fn version_text(version : @types.Version) -> String {
  match version {
    Http10 => "HTTP/1.0"
    Http11 => "HTTP/1.1"
    Http2 => "HTTP/2"
    Http3 => "HTTP/3"
  }
}

///|
fn append_headers(
  out : Array[Byte],
  headers : @types.HeaderMap,
  framing : BodyFraming,
  preserve_content_length : Bool,
) -> Result[Unit, Http1Error] {
  for field in headers.fields() {
    let name = field.name.value
    if name == "transfer-encoding" ||
      (name == "content-length" && !preserve_content_length) {
      continue
    }
    push_text(out, name)
    push_text(out, ": ")
    push_bytes(out, field.value.bytes)
    push_text(out, "\r\n")
  }
  match framing {
    ContentLength(size) =>
      push_text(out, "content-length: " + size.to_string() + "\r\n")
    Chunked => push_text(out, "transfer-encoding: chunked\r\n")
    NoBody | CloseDelimited => ()
  }
  Ok(())
}

///|
pub fn encode_request_head(
  request : @types.Request[Unit],
  framing : BodyFraming,
) -> Result[Bytes, Http1Error] {
  if framing is CloseDelimited {
    return Err(InvalidFraming("requests cannot be close-delimited"))
  }
  if request.version == Http2 || request.version == Http3 {
    return Err(InvalidStartLine("non-HTTP/1 version in HTTP/1 wire encoding"))
  }
  if request.http_method.validate() is Err(_) {
    return Err(InvalidStartLine("invalid request method"))
  }
  if request.uri.validate_request_target(request.http_method) is Err(_) {
    return Err(InvalidStartLine("invalid request target"))
  }
  match http1_validate_host(request.headers) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if request.version == Http11 &&
    request.headers.get_all_string("host").is_empty() {
    return Err(InvalidHeader("HTTP/1.1 request requires Host"))
  }
  match http1_validate_connection_headers(request.headers) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match validate_outgoing_framing(request.headers, framing, request.version) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let out : Array[Byte] = []
  push_text(
    out,
    request.http_method.as_str() +
    " " +
    request.uri.value +
    " " +
    version_text(request.version) +
    "\r\n",
  )
  match append_headers(out, request.headers, framing, false) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  push_text(out, "\r\n")
  Ok(Bytes::from_array(out))
}

///|
fn default_reason(status : Int) -> String {
  match status {
    100 => "Continue"
    101 => "Switching Protocols"
    200 => "OK"
    201 => "Created"
    204 => "No Content"
    304 => "Not Modified"
    400 => "Bad Request"
    404 => "Not Found"
    413 => "Payload Too Large"
    500 => "Internal Server Error"
    502 => "Bad Gateway"
    503 => "Service Unavailable"
    _ => "Unknown"
  }
}

///|
pub fn encode_response_head(
  response : @types.Response[Unit],
  request_method : @types.Method,
  framing : BodyFraming,
) -> Result[Bytes, Http1Error] {
  if response.version == Http2 || response.version == Http3 {
    return Err(InvalidStartLine("non-HTTP/1 version in HTTP/1 wire encoding"))
  }
  if response.status < 100 || response.status > 999 {
    return Err(InvalidStartLine("status code is out of range"))
  }
  if !@types.response_allows_body(request_method, response.status) &&
    framing != NoBody {
    return Err(
      InvalidFraming("response status or request method forbids a body"),
    )
  }
  if (response.status >= 100 && response.status < 200) ||
    response.status == 204 ||
    (
      request_method == Connect &&
      response.status >= 200 &&
      response.status < 300
    ) {
    if response.headers.content_length() is Ok(Some(_)) ||
      !response.headers.get_all_string("transfer-encoding").is_empty() {
      return Err(
        InvalidFraming("body framing header is forbidden for this response"),
      )
    }
  }
  let permit_head_length = request_method == Head || response.status == 304
  match
    validate_outgoing_framing(
      response.headers,
      framing,
      response.version,
      allow_nonzero_content_length_without_body=permit_head_length,
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let out : Array[Byte] = []
  push_text(
    out,
    version_text(response.version) +
    " " +
    response.status.to_string() +
    " " +
    default_reason(response.status) +
    "\r\n",
  )
  let preserve_content_length = request_method == Head || response.status == 304
  match
    append_headers(out, response.headers, framing, preserve_content_length) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  push_text(out, "\r\n")
  Ok(Bytes::from_array(out))
}

///|
pub fn encode_body_data(
  data : Bytes,
  framing : BodyFraming,
) -> Result[Bytes, Http1Error] {
  match framing {
    NoBody =>
      if data.is_empty() {
        Ok(b"")
      } else {
        Err(InvalidFraming("body data for no-body message"))
      }
    ContentLength(_) | CloseDelimited => Ok(data)
    Chunked => {
      if data.is_empty() {
        return Ok(b"")
      }
      let out : Array[Byte] = []
      push_text(out, data.length().to_string(radix=16) + "\r\n")
      push_bytes(out, data)
      push_text(out, "\r\n")
      Ok(Bytes::from_array(out))
    }
  }
}

///|
pub fn encode_body_end(
  framing : BodyFraming,
  trailers? : @types.HeaderMap = @types.HeaderMap::new(),
) -> Result[Bytes, Http1Error] {
  if framing != Chunked {
    if !trailers.is_empty() {
      return Err(InvalidFraming("trailers require chunked framing"))
    }
    return Ok(b"")
  }
  let out : Array[Byte] = []
  push_text(out, "0\r\n")
  for field in trailers.fields() {
    if http1_forbidden_trailer(field.name.value) {
      return Err(InvalidHeader("forbidden trailer field"))
    }
    push_text(out, field.name.value + ": ")
    push_bytes(out, field.value.bytes)
    push_text(out, "\r\n")
  }
  push_text(out, "\r\n")
  Ok(Bytes::from_array(out))
}
