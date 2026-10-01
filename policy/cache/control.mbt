///|
fn cache_trim(value : StringView) -> String {
  value.trim().to_owned()
}

///|
fn cache_lower(value : String) -> String {
  value.to_lower()
}

///|
fn cache_parse_nonnegative(value : String) -> Result[Int64, CacheError] {
  let text = cache_trim(value)
  if text.is_empty() {
    return Err(InvalidCacheControl)
  }
  let bytes = @utf8.encode(text)
  let mut result = 0L
  for byte in bytes {
    if byte < b'0' || byte > b'9' {
      return Err(InvalidCacheControl)
    }
    let digit = (byte.to_int() - 48).to_int64()
    if result > (0x7fffffffffffffffL - digit) / 10L {
      return Err(InvalidCacheControl)
    }
    result = result * 10L + digit
  }
  Ok(result)
}

///|
fn cache_directive_parts(value : String) -> Array[String] {
  let parts : Array[String] = []
  let mut start = 0
  let mut quoted = false
  let mut escaped = false
  let mut index = 0
  while index < value.length() {
    let char = value.get_char(index).unwrap()
    if escaped {
      escaped = false
    } else if quoted && char == '\\' {
      escaped = true
    } else if char == '"' {
      quoted = !quoted
    } else if char == ',' && !quoted {
      parts.push(value[start:index].to_owned())
      start = index + 1
    }
    index += 1
  }
  parts.push(value[start:].to_owned())
  parts
}

///|
fn cache_directive_value(
  value : String,
) -> Result[(String, String?), CacheError] {
  let text = cache_trim(value)
  let mut equals = -1
  for index in 0..<text.length() {
    if text[index] == '=' {
      equals = index
      break
    }
  }
  if equals < 0 {
    let name = cache_lower(text)
    if name.is_empty() {
      return Err(InvalidCacheControl)
    }
    return Ok((name, None))
  }
  let position = equals
  let name = cache_lower(cache_trim(text[:position]))
  let raw = cache_trim(text[position + 1:])
  if name.is_empty() || raw.is_empty() {
    return Err(InvalidCacheControl)
  }
  if raw.length() >= 2 && raw.has_prefix("\"") && raw.has_suffix("\"") {
    return Ok((name, Some(raw[1:raw.length() - 1].to_owned())))
  }
  if raw.contains("\"") {
    return Err(InvalidCacheControl)
  }
  Ok((name, Some(raw)))
}

///|
/// Parses all Cache-Control field lines. Unknown directives are retained only
/// for forward compatibility by ignoring them; malformed known directives
/// fail closed.
pub fn parse_cache_control(
  headers : @types.HeaderMap,
  max_directives? : Int = 64,
) -> Result[CacheControl, CacheError] {
  if max_directives < 1 {
    return Err(InvalidCacheControl)
  }
  let result = CacheControl::empty()
  let mut count = 0
  for header in headers.get_all_string("cache-control") {
    for part in cache_directive_parts(header.to_string_lossy()) {
      count += 1
      if count > max_directives {
        return Err(InvalidCacheControl)
      }
      let (name, argument) = match cache_directive_value(part) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      match name {
        "no-cache" => result.no_cache = true
        "no-store" => result.no_store = true
        "must-revalidate" => result.must_revalidate = true
        "proxy-revalidate" => result.proxy_revalidate = true
        "public" => result.public = true
        "private" => result.private = true
        "immutable" => result.immutable = true
        "no-transform" => result.no_transform = true
        "only-if-cached" => result.only_if_cached = true
        "max-age" => {
          let value = match argument {
            Some(value) =>
              match cache_parse_nonnegative(value) {
                Ok(value) => value
                Err(error) => return Err(error)
              }
            None => return Err(InvalidCacheControl)
          }
          result.max_age = Some(value)
        }
        "s-maxage" => {
          let value = match argument {
            Some(value) =>
              match cache_parse_nonnegative(value) {
                Ok(value) => value
                Err(error) => return Err(error)
              }
            None => return Err(InvalidCacheControl)
          }
          result.s_maxage = Some(value)
        }
        "max-stale" =>
          result.max_stale = match argument {
            None => {
              result.max_stale_any = true
              None
            }
            Some(value) =>
              Some(
                match cache_parse_nonnegative(value) {
                  Ok(value) => value
                  Err(error) => return Err(error)
                },
              )
          }
        "min-fresh" => {
          let value = match argument {
            Some(value) =>
              match cache_parse_nonnegative(value) {
                Ok(value) => value
                Err(error) => return Err(error)
              }
            None => return Err(InvalidCacheControl)
          }
          result.min_fresh = Some(value)
        }
        "stale-while-revalidate" => {
          let value = match argument {
            Some(value) =>
              match cache_parse_nonnegative(value) {
                Ok(value) => value
                Err(error) => return Err(error)
              }
            None => return Err(InvalidCacheControl)
          }
          result.stale_while_revalidate = Some(value)
        }
        "stale-if-error" => {
          let value = match argument {
            Some(value) =>
              match cache_parse_nonnegative(value) {
                Ok(value) => value
                Err(error) => return Err(error)
              }
            None => return Err(InvalidCacheControl)
          }
          result.stale_if_error = Some(value)
        }
        _ => ()
      }
    }
  }
  Ok(result)
}

///|
pub fn cache_control_value(control : CacheControl, name : String) -> Bool {
  match name.to_lower() {
    "no-cache" => control.no_cache
    "no-store" => control.no_store
    "must-revalidate" => control.must_revalidate
    "proxy-revalidate" => control.proxy_revalidate
    "public" => control.public
    "private" => control.private
    "immutable" => control.immutable
    "no-transform" => control.no_transform
    "only-if-cached" => control.only_if_cached
    _ => false
  }
}

///|
pub fn parse_vary(
  headers : @types.HeaderMap,
  max_fields? : Int = 32,
) -> Result[(Bool, Array[String]), CacheError] {
  if max_fields < 1 {
    return Err(InvalidVary)
  }
  let fields : Array[String] = []
  for header in headers.get_all_string("vary") {
    for part in header.to_string_lossy().split(",") {
      let name = cache_trim(part)
      if name == "*" {
        return Ok((true, []))
      }
      match @types.HeaderName::parse(name) {
        Ok(parsed) => {
          let normalized = parsed.value
          let mut duplicate = false
          for existing in fields {
            if existing == normalized {
              duplicate = true
              break
            }
          }
          if !duplicate {
            fields.push(normalized)
          }
        }
        Err(_) => return Err(InvalidVary)
      }
      if fields.length() > max_fields {
        return Err(InvalidVary)
      }
    }
  }
  Ok((false, fields))
}

///|
pub fn parse_age(headers : @types.HeaderMap) -> Result[Int64, CacheError] {
  let values = headers.get_all_string("age")
  if values.is_empty() {
    return Ok(0L)
  }
  let mut result : Int64? = None
  for value in values {
    let parsed = match cache_parse_nonnegative(value.to_string_lossy()) {
      Ok(value) => value
      Err(_) => return Err(InvalidAge)
    }
    match result {
      None => result = Some(parsed)
      Some(previous) if previous == parsed => ()
      Some(_) => return Err(InvalidAge)
    }
  }
  Ok(result.unwrap_or(0L))
}
