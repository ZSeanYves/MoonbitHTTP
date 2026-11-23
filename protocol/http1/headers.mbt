///|
fn decode_header_line(
  line : Bytes,
  headers : @types.HeaderMap,
) -> Result[Unit, Http1Error] {
  let mut colon = -1
  for i in 0..<line.length() {
    if line[i] == b':' {
      colon = i
      break
    }
  }
  if colon <= 0 {
    return Err(InvalidHeader("header field has no valid name"))
  }
  let name_bytes = line[:colon].to_owned()
  let mut start = colon + 1
  let mut end = line.length()
  while start < end && (line[start] == b' ' || line[start] == b'\t') {
    start += 1
  }
  while end > start && (line[end - 1] == b' ' || line[end - 1] == b'\t') {
    end -= 1
  }
  let name_string = @utf8.decode(name_bytes) catch {
    _ => return Err(InvalidHeader("header name is not ASCII"))
  }
  let name = match @types.HeaderName::parse(name_string) {
    Ok(value) => value
    Err(_) => return Err(InvalidHeader("invalid header name"))
  }
  let value = match @types.HeaderValue::from_bytes(line[start:end].to_owned()) {
    Ok(value) => value
    Err(_) => return Err(InvalidHeader("invalid header value"))
  }
  headers.append(name, value)
  Ok(())
}

///|
fn http1_forbidden_trailer(name : String) -> Bool {
  name == "content-length" ||
  name == "transfer-encoding" ||
  name == "host" ||
  name == "trailer" ||
  name == "connection" ||
  name == "keep-alive" ||
  name == "upgrade" ||
  name == "te" ||
  name == "proxy-authenticate" ||
  name == "proxy-authorization"
}

///|
fn http1_validate_trailer_fields(
  headers : @types.HeaderMap,
) -> Result[Unit, Http1Error] {
  for field in headers.fields() {
    if http1_forbidden_trailer(field.name.value) {
      return Err(InvalidHeader("forbidden trailer field"))
    }
  }
  Ok(())
}

///|
fn http1_validate_request_headers(
  headers : @types.HeaderMap,
  version : @types.Version,
) -> Result[Unit, Http1Error] {
  match headers.get_all_string("host") {
    [] if version == Http11 =>
      return Err(InvalidHeader("HTTP/1.1 request requires Host"))
    [] => ()
    [value] =>
      if @types.Authority::parse_endpoint(
          value.to_string_lossy().trim().to_owned(),
        )
        is Err(_) {
        return Err(InvalidHeader("invalid Host field"))
      }
    _ => return Err(InvalidHeader("request contains multiple Host fields"))
  }
  for value in headers.get_all_string("te") {
    for token in value.to_string_lossy().split(",") {
      let normalized = token.trim().to_owned().to_lower()
      if normalized != "trailers" && !normalized.is_empty() {
        return Err(InvalidHeader("unsupported TE request coding"))
      }
    }
  }
  for value in headers.get_all_string("trailer") {
    for token in value.to_string_lossy().split(",") {
      let name = token.trim().to_owned()
      match @types.HeaderName::parse(name) {
        Ok(parsed) if !http1_forbidden_trailer(parsed.value) => ()
        _ => return Err(InvalidHeader("invalid Trailer declaration"))
      }
    }
  }
  Ok(())
}

///|
pub struct RequestExpectations {
  continue_requested : Bool
  unsupported : Bool
}

///|
/// Classifies all Expect lines. Commas inside quoted extension values are
/// data. Only a bare, case-insensitive 100-continue requests the handshake.
pub fn RequestExpectations::from_headers(
  headers : @types.HeaderMap,
) -> RequestExpectations {
  let mut continue_requested = false
  let mut unsupported = false
  for value in headers.get_all_string("expect") {
    let text = value.to_string_lossy()
    let mut start = 0
    let mut quoted = false
    let mut escaped = false
    for i in 0..<=text.length() {
      if i == text.length() || (!quoted && text[i] == ',') {
        let item = text[start:i].trim(chars=" \t")
        if !item.is_empty() {
          if item.equal_ignore_ascii_case("100-continue") {
            continue_requested = true
          } else {
            unsupported = true
          }
        }
        start = i + 1
      } else if escaped {
        escaped = false
      } else if quoted && text[i] == '\\' {
        escaped = true
      } else if text[i] == '"' {
        quoted = !quoted
      }
    }
  }
  { continue_requested, unsupported, }
}
