///|
fn h2_field_text(value : BytesView) -> String? {
  Some(@utf8.decode(value)) catch {
    _ => None
  }
}

///|
fn h2_ascii_equal_fold(value : BytesView, expected : BytesView) -> Bool {
  if value.length() != expected.length() {
    return false
  }
  for index in 0..<value.length() {
    let byte = value[index]
    let folded = if byte >= b'A' && byte <= b'Z' {
      (byte.to_int() + 32).to_byte()
    } else {
      byte
    }
    if folded != expected[index] {
      return false
    }
  }
  true
}

///|
fn h2_connection_specific(name : String) -> Bool {
  name == "connection" ||
  name == "proxy-connection" ||
  name == "upgrade" ||
  name == "keep-alive" ||
  name == "transfer-encoding"
}

///|
fn append_h2_regular_header(
  headers : @types.HeaderMap,
  field : @http2.HpackHeader,
) -> Bool {
  let name = match @types.HeaderName::parse(field.name) {
    Ok(value) if value.value == field.name => value
    _ => return false
  }
  let value = match @types.HeaderValue::from_bytes(field.value) {
    Ok(value) => value
    Err(_) => return false
  }
  headers.append(name, value)
  true
}

///|
fn h2_forbidden_trailer(name : String) -> Bool {
  h2_connection_specific(name) ||
  name == "content-length" ||
  name == "host" ||
  name == "te" ||
  name == "trailer"
}
