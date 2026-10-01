///|
fn cookie_find_byte(input : BytesView, target : Byte, start : Int) -> Int {
  let mut index = start.max(0)
  while index < input.length() {
    if input[index] == target {
      return index
    }
    index += 1
  }
  input.length()
}

///|
fn cookie_trim_ows(input : BytesView) -> BytesView {
  let mut start = 0
  let mut end = input.length()
  while start < end && (input[start] == b' ' || input[start] == b'\t') {
    start += 1
  }
  while end > start && (input[end - 1] == b' ' || input[end - 1] == b'\t') {
    end -= 1
  }
  input[start:end]
}

///|
fn cookie_forbidden_control(input : BytesView) -> Bool {
  for byte in input {
    let value = byte.to_int()
    if value <= 0x08 || (value >= 0x0a && value <= 0x1f) || value == 0x7f {
      return true
    }
  }
  false
}

///|
fn cookie_ascii_equal_fold(input : BytesView, expected : BytesView) -> Bool {
  if input.length() != expected.length() {
    return false
  }
  for index in 0..<input.length() {
    if cookie_ascii_lower_byte(input[index]) !=
      cookie_ascii_lower_byte(expected[index]) {
      return false
    }
  }
  true
}

///|
fn cookie_ascii_prefix_fold(input : BytesView, expected : BytesView) -> Bool {
  if input.length() < expected.length() {
    return false
  }
  cookie_ascii_equal_fold(input[:expected.length()], expected)
}

///|
fn cookie_ascii_text(input : BytesView) -> String? {
  for byte in input {
    if byte < b'!' || byte > b'~' {
      return None
    }
  }
  Some(@utf8.decode(input) catch { _ => return None })
}

///|
fn cookie_parse_max_age(input : BytesView, maximum : Int64) -> Int64? {
  if input.is_empty() {
    return None
  }
  let negative = input[0] == b'-'
  let start = if negative { 1 } else { 0 }
  if start == input.length() {
    return None
  }
  let mut value = 0L
  for index in start..<input.length() {
    let byte = input[index]
    if byte < b'0' || byte > b'9' {
      return None
    }
    let digit = (byte.to_int() - 48).to_int64()
    if value > (maximum - digit) / 10L {
      return Some(if negative { 0L } else { maximum })
    }
    value = value * 10L + digit
  }
  Some(if negative { 0L } else { value.min(maximum) })
}

///|
fn parse_set_cookie(
  header : @types.HeaderValue,
  limits : CookieLimits,
) -> Result[ParsedSetCookie, CookieRejection] {
  let input = header.bytes
  if input.length() > limits.max_set_cookie_bytes {
    return Err(CookieTooLarge)
  }
  let first_semicolon = cookie_find_byte(input, b';', 0)
  let pair = input[:first_semicolon]
  let equals = cookie_find_byte(pair, b'=', 0)
  if equals == pair.length() {
    return Err(MalformedSetCookie)
  }
  let name = cookie_trim_ows(pair[:equals])
  let value = cookie_trim_ows(pair[equals + 1:])
  if (name.is_empty() && value.is_empty()) ||
    cookie_forbidden_control(name) ||
    cookie_forbidden_control(value) {
    return Err(MalformedSetCookie)
  }
  if name.length() > limits.max_cookie_bytes - value.length() {
    return Err(CookieTooLarge)
  }
  let mut domain : String? = None
  let mut path : Bytes? = None
  let mut explicit_path = false
  let mut max_age_seconds : Int64? = None
  let mut expires_seconds : Int64? = None
  let mut secure = false
  let mut http_only = false
  let mut same_site = SameSiteDefault
  let mut partitioned = false
  let mut cursor = first_semicolon
  while cursor < input.length() {
    cursor += 1
    let next = cookie_find_byte(input, b';', cursor)
    let attribute = cookie_trim_ows(input[cursor:next])
    cursor = next
    if attribute.is_empty() {
      continue
    }
    let attribute_equals = cookie_find_byte(attribute, b'=', 0)
    let attribute_name = cookie_trim_ows(attribute[:attribute_equals])
    let attribute_value = if attribute_equals < attribute.length() {
      cookie_trim_ows(attribute[attribute_equals + 1:])
    } else {
      attribute[attribute.length():]
    }
    if cookie_ascii_equal_fold(attribute_name, b"expires") {
      match parse_cookie_date(attribute_value) {
        Some(value) => expires_seconds = Some(value)
        None => ()
      }
    } else if cookie_ascii_equal_fold(attribute_name, b"max-age") {
      match cookie_parse_max_age(attribute_value, limits.max_lifetime_seconds) {
        Some(value) => max_age_seconds = Some(value)
        None => ()
      }
    } else if cookie_ascii_equal_fold(attribute_name, b"domain") {
      if attribute_value.length() > limits.max_attribute_bytes {
        return Err(CookieAttributeTooLarge)
      }
      let domain_value = if attribute_value.has_prefix(b".") {
        attribute_value[1:]
      } else {
        attribute_value
      }
      domain = match cookie_ascii_text(domain_value) {
        Some(value) if !value.is_empty() && !value.has_suffix(".") =>
          Some(value)
        _ => return Err(InvalidCookieDomain)
      }
    } else if cookie_ascii_equal_fold(attribute_name, b"path") {
      if attribute_value.length() > limits.max_attribute_bytes {
        return Err(CookieAttributeTooLarge)
      }
      explicit_path = true
      path = if attribute_value.has_prefix(b"/") {
        Some(attribute_value.to_owned())
      } else {
        None
      }
    } else if cookie_ascii_equal_fold(attribute_name, b"secure") {
      secure = true
    } else if cookie_ascii_equal_fold(attribute_name, b"httponly") {
      http_only = true
    } else if cookie_ascii_equal_fold(attribute_name, b"samesite") {
      same_site = if cookie_ascii_equal_fold(attribute_value, b"strict") {
        SameSiteStrict
      } else if cookie_ascii_equal_fold(attribute_value, b"lax") {
        SameSiteLax
      } else if cookie_ascii_equal_fold(attribute_value, b"none") {
        SameSiteNone
      } else {
        SameSiteDefault
      }
    } else if cookie_ascii_equal_fold(attribute_name, b"partitioned") {
      partitioned = true
    }
  }
  Ok({
    name: name.to_owned(),
    value: value.to_owned(),
    domain,
    path,
    explicit_path,
    max_age_seconds,
    expires_seconds,
    secure,
    http_only,
    same_site,
    partitioned,
  })
}
