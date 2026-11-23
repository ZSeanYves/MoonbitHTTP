///|
fn h2_field_text(value : BytesView) -> String? {
  Some(@utf8.decode(value)) catch {
    _ => None
  }
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
