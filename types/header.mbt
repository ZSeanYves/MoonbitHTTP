///|
pub(all) suberror HeaderError {
  InvalidName(String)
  InvalidValue(String)
  InvalidContentLength
  ConflictingContentLength
  ContentLengthOverflow
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
    let value = b.to_int()
    if (value < 0x20 && b != b'\t') || value == 0x7f {
      return Err(InvalidValue("header value contains a control byte"))
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
  { entries: [], }
}

///|
pub fn HeaderMap::copy(self : HeaderMap) -> HeaderMap {
  { entries: self.entries.copy(), }
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
  self.entries.push({ name, value, })
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

///|
fn parse_decimal_bytes(value : BytesView) -> Result[Int, HeaderError] {
  if value.is_empty() {
    return Err(InvalidContentLength)
  }
  let mut result = 0
  for byte in value {
    if byte < b'0' || byte > b'9' {
      return Err(InvalidContentLength)
    }
    let digit = byte.to_int() - 48
    if result > (0x7fffffff - digit) / 10 {
      return Err(ContentLengthOverflow)
    }
    result = result * 10 + digit
  }
  Ok(result)
}

///|
/// Parses all Content-Length field lines and comma-separated members. Repeated
/// values are accepted only when their decimal values are identical.
pub fn HeaderMap::content_length(self : HeaderMap) -> Result[Int?, HeaderError] {
  let mut expected : Int? = None
  for value in self.get_all_string("content-length") {
    let bytes = value.bytes
    let mut start = 0
    while start <= bytes.length() {
      let mut end = start
      while end < bytes.length() && bytes[end] != b',' {
        end += 1
      }
      let mut item_start = start
      let mut item_end = end
      while item_start < item_end &&
            (bytes[item_start] == b' ' || bytes[item_start] == b'\t') {
        item_start += 1
      }
      while item_end > item_start &&
            (bytes[item_end - 1] == b' ' || bytes[item_end - 1] == b'\t') {
        item_end -= 1
      }
      let parsed = match parse_decimal_bytes(bytes[item_start:item_end]) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      match expected {
        Some(value) if value != parsed => return Err(ConflictingContentLength)
        None => expected = Some(parsed)
        _ => ()
      }
      if end == bytes.length() {
        break
      }
      start = end + 1
    }
  }
  Ok(expected)
}
