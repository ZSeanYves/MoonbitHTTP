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
