///|
fn split_start_line(line : Bytes) -> Result[(Bytes, Bytes, Bytes), Http1Error] {
  let mut first = -1
  let mut second = -1
  for i in 0..<line.length() {
    if line[i] == b' ' {
      if first < 0 {
        first = i
      } else if second < 0 {
        second = i
      } else {
        return Err(InvalidStartLine("too many separators"))
      }
    }
  }
  if first <= 0 || second <= first + 1 || second + 1 >= line.length() {
    return Err(InvalidStartLine("expected three non-empty components"))
  }
  Ok(
    (
      line[:first].to_owned(),
      line[first + 1:second].to_owned(),
      line[second + 1:].to_owned(),
    ),
  )
}

///|
fn parse_method(bytes : Bytes) -> Result[@types.Method, Http1Error] {
  match @types.Method::parse_bytes(bytes) {
    Ok(value) => Ok(value)
    Err(_) => Err(InvalidStartLine("invalid method token"))
  }
}

///|
fn parse_version(bytes : Bytes) -> Result[@types.Version, Http1Error] {
  match bytes {
    b"HTTP/1.0" => Ok(Http10)
    b"HTTP/1.1" => Ok(Http11)
    _ => Err(InvalidStartLine("unsupported HTTP version"))
  }
}

///|
fn parse_request_line(
  line : Bytes,
) -> Result[(@types.Method, @types.Uri, @types.Version), Http1Error] {
  let (method_bytes, target, version) = match split_start_line(line) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let http_method = match parse_method(method_bytes) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let target = @utf8.decode(target) catch {
    _ => return Err(InvalidStartLine("request target is not UTF-8"))
  }
  let uri = match @types.Uri::parse_request_target(target, http_method) {
    Ok(value) => value
    Err(_) => return Err(InvalidStartLine("invalid request target"))
  }
  let version = match parse_version(version) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok((http_method, uri, version))
}

///|
fn parse_response_line(
  line : Bytes,
) -> Result[(@types.Version, Int), Http1Error] {
  let mut first = -1
  let mut second = line.length()
  for i in 0..<line.length() {
    if line[i] == b' ' {
      if first < 0 {
        first = i
      } else {
        second = i
        break
      }
    }
  }
  if first <= 0 || second != first + 4 {
    return Err(InvalidStartLine("invalid status line"))
  }
  let version = match parse_version(line[:first].to_owned()) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let status_string = @utf8.decode(line[first + 1:second]) catch {
    _ => return Err(InvalidStartLine("invalid status code"))
  }
  for byte in @utf8.encode(status_string) {
    if byte < b'0' || byte > b'9' {
      return Err(InvalidStartLine("invalid status code"))
    }
  }
  let status = @string.parse_int(status_string) catch {
    _ => return Err(InvalidStartLine("invalid status code"))
  }
  if status < 100 || status > 999 {
    return Err(InvalidStartLine("status code is out of range"))
  }
  Ok((version, status))
}
