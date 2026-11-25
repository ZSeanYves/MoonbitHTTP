///|
fn h2_field_text(value : BytesView) -> String? {
  Some(@utf8.decode(value)) catch {
    _ => None
  }
}

///|
fn append_regular_header(
  headers : @types.HeaderMap,
  raw_name : String,
  raw_value : Bytes,
) -> Bool {
  let name = match @types.HeaderName::parse(raw_name) {
    Ok(value) if value.value == raw_name => value
    _ => return false
  }
  let value = match @types.HeaderValue::from_bytes(raw_value) {
    Ok(value) => value
    Err(_) => return false
  }
  headers.append(name, value)
  true
}

///|
/// HTTP/2 and HTTP/3 permit a sender to split Cookie for compression. Restore
/// its HTTP semantics at the application boundary, preserving opaque values.
fn join_request_cookies(headers : @types.HeaderMap) -> Unit {
  let cookies = headers.get_all_string("cookie")
  guard cookies.length() > 1 else { return }
  let joined = @buffer.Buffer()
  for i, cookie in cookies {
    if i > 0 {
      joined.write_bytes(b"; ")
    }
    joined.write_bytes(cookie.bytes)
  }
  headers.set(
    @types.HeaderName::parse("cookie").unwrap(),
    @types.HeaderValue::from_bytes(joined.to_bytes()).unwrap(),
  )
}

///|
/// Decide from the received fields before opening the application's upload.
/// Query framing only when a peer actually requests a continue response.
fn expectation_response(
  headers : @types.HeaderMap,
  content_pending : () -> Bool,
) -> Int32? {
  let expectation = @types.RequestExpectations::from_headers(headers)
  if expectation.unsupported {
    Some(417)
  } else if expectation.continue_requested && content_pending() {
    Some(100)
  } else {
    None
  }
}
