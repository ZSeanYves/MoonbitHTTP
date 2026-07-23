///|
pub(all) suberror HeaderError {
  InvalidName(String)
  InvalidValue(String)
} derive(Debug, Eq)

///|
pub(all) struct HeaderName {
  value : String
} derive(Debug, Eq, Compare, Hash)

///|
pub(all) struct HeaderValue {
  bytes : Bytes
} derive(Debug, Eq)

///|
pub(all) struct HeaderField {
  name : HeaderName
  value : HeaderValue
} derive(Debug, Eq)

///|
pub struct HeaderMap {
  mut entries : Array[HeaderField]
}

///|
fn is_token_byte(b : Byte) -> Bool {
  let n = b.to_int()
  (n >= 48 && n <= 57) ||
  (n >= 65 && n <= 90) ||
  (n >= 97 && n <= 122) ||
  b == b'!' ||
  b == b'#' ||
  b == b'$' ||
  b == b'%' ||
  b == b'&' ||
  b == b'\'' ||
  b == b'*' ||
  b == b'+' ||
  b == b'-' ||
  b == b'.' ||
  b == b'^' ||
  b == b'_' ||
  b == b'`' ||
  b == b'|' ||
  b == b'~'
}

///|
pub fn HeaderName::parse(raw : String) -> Result[HeaderName, HeaderError] {
  let bytes = @utf8.encode(raw)
  if bytes.is_empty() {
    return Err(InvalidName("header name is empty"))
  }
  let normalized = FixedArray::make(bytes.length(), b'0')
  for i in 0..<bytes.length() {
    let b = bytes[i]
    if !is_token_byte(b) {
      return Err(InvalidName("invalid byte in header name"))
    }
    normalized[i] = if b >= b'A' && b <= b'Z' {
      (b.to_int() + 32).to_byte()
    } else {
      b
    }
  }
  let value = @utf8.decode(normalized.unsafe_reinterpret_as_bytes()) catch {
    _ => return Err(InvalidName("header name is not valid ASCII"))
  }
  Ok({ value, })
}

///|
pub fn HeaderValue::from_bytes(
  bytes : Bytes,
) -> Result[HeaderValue, HeaderError] {
  for b in bytes {
    if b == b'\r' || b == b'\n' || b == b'\x00' {
      return Err(InvalidValue("header value contains CR, LF, or NUL"))
    }
  }
  Ok({ bytes, })
}

///|
pub fn HeaderValue::from_string(
  value : String,
) -> Result[HeaderValue, HeaderError] {
  HeaderValue::from_bytes(@utf8.encode(value))
}

///|
pub fn HeaderValue::to_string_lossy(self : HeaderValue) -> String {
  @utf8.decode_lossy(self.bytes)
}

///|
pub fn HeaderMap::new() -> HeaderMap {
  { entries: [] }
}

///|
pub fn HeaderMap::length(self : HeaderMap) -> Int {
  self.entries.length()
}

///|
pub fn HeaderMap::is_empty(self : HeaderMap) -> Bool {
  self.entries.is_empty()
}

///|
pub fn HeaderMap::append(
  self : HeaderMap,
  name : HeaderName,
  value : HeaderValue,
) -> Unit {
  self.entries.push({ name, value })
}

///|
pub fn HeaderMap::append_string(
  self : HeaderMap,
  name : String,
  value : String,
) -> Result[Unit, HeaderError] {
  let name = match HeaderName::parse(name) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let value = match HeaderValue::from_string(value) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  self.append(name, value)
  Ok(())
}

///|
pub fn HeaderMap::remove(self : HeaderMap, name : HeaderName) -> Unit {
  let kept : Array[HeaderField] = []
  for field in self.entries {
    if field.name != name {
      kept.push(field)
    }
  }
  self.entries = kept
}

///|
pub fn HeaderMap::set(
  self : HeaderMap,
  name : HeaderName,
  value : HeaderValue,
) -> Unit {
  self.remove(name)
  self.append(name, value)
}

///|
pub fn HeaderMap::get(self : HeaderMap, name : HeaderName) -> HeaderValue? {
  for field in self.entries {
    if field.name == name {
      return Some(field.value)
    }
  }
  None
}

///|
pub fn HeaderMap::get_string(self : HeaderMap, name : String) -> HeaderValue? {
  match HeaderName::parse(name) {
    Ok(name) => self.get(name)
    Err(_) => None
  }
}

///|
pub fn HeaderMap::get_all(
  self : HeaderMap,
  name : HeaderName,
) -> Array[HeaderValue] {
  let values : Array[HeaderValue] = []
  for field in self.entries {
    if field.name == name {
      values.push(field.value)
    }
  }
  values
}

///|
pub fn HeaderMap::get_all_string(
  self : HeaderMap,
  name : String,
) -> Array[HeaderValue] {
  match HeaderName::parse(name) {
    Ok(name) => self.get_all(name)
    Err(_) => []
  }
}

///|
pub fn HeaderMap::contains(self : HeaderMap, name : HeaderName) -> Bool {
  self.get(name) is Some(_)
}

///|
pub fn HeaderMap::fields(self : HeaderMap) -> Array[HeaderField] {
  self.entries.copy()
}
