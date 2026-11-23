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
