///|
fn qpack_static_get(index : Int) -> (String, String)? {
  match index {
    0 => Some((":authority", ""))
    1 => Some((":path", "/"))
    2 => Some(("age", "0"))
    3 => Some(("content-disposition", ""))
    4 => Some(("content-length", "0"))
    5 => Some(("cookie", ""))
    6 => Some(("date", ""))
    7 => Some(("etag", ""))
    8 => Some(("if-modified-since", ""))
    9 => Some(("if-none-match", ""))
    10 => Some(("last-modified", ""))
    11 => Some(("link", ""))
    12 => Some(("location", ""))
    13 => Some(("referer", ""))
    14 => Some(("set-cookie", ""))
    15 => Some((":method", "CONNECT"))
    16 => Some((":method", "DELETE"))
    17 => Some((":method", "GET"))
    18 => Some((":method", "HEAD"))
    19 => Some((":method", "OPTIONS"))
    20 => Some((":method", "POST"))
    21 => Some((":method", "PUT"))
    22 => Some((":scheme", "http"))
    23 => Some((":scheme", "https"))
    24 => Some((":status", "103"))
    25 => Some((":status", "200"))
    26 => Some((":status", "304"))
    27 => Some((":status", "404"))
    28 => Some((":status", "503"))
    29 => Some(("accept", "*/*"))
    30 => Some(("accept", "application/dns-message"))
    31 => Some(("accept-encoding", "gzip, deflate, br"))
    32 => Some(("accept-ranges", "bytes"))
    33 => Some(("access-control-allow-headers", "cache-control"))
    34 => Some(("access-control-allow-headers", "content-type"))
    35 => Some(("access-control-allow-origin", "*"))
    36 => Some(("cache-control", "max-age=0"))
    37 => Some(("cache-control", "max-age=2592000"))
    38 => Some(("cache-control", "max-age=604800"))
    39 => Some(("cache-control", "no-cache"))
    40 => Some(("cache-control", "no-store"))
    41 => Some(("cache-control", "public, max-age=31536000"))
    42 => Some(("content-encoding", "br"))
    43 => Some(("content-encoding", "gzip"))
    44 => Some(("content-type", "application/dns-message"))
    45 => Some(("content-type", "application/javascript"))
    46 => Some(("content-type", "application/json"))
    47 => Some(("content-type", "application/x-www-form-urlencoded"))
    48 => Some(("content-type", "image/gif"))
    49 => Some(("content-type", "image/jpeg"))
    50 => Some(("content-type", "image/png"))
    51 => Some(("content-type", "text/css"))
    52 => Some(("content-type", "text/html; charset=utf-8"))
    53 => Some(("content-type", "text/plain"))
    54 => Some(("content-type", "text/plain;charset=utf-8"))
    55 => Some(("range", "bytes=0-"))
    56 => Some(("strict-transport-security", "max-age=31536000"))
    57 =>
      Some(("strict-transport-security", "max-age=31536000; includesubdomains"))
    58 =>
      Some(
        (
          "strict-transport-security", "max-age=31536000; includesubdomains; preload",
        ),
      )
    59 => Some(("vary", "accept-encoding"))
    60 => Some(("vary", "origin"))
    61 => Some(("x-content-type-options", "nosniff"))
    62 => Some(("x-xss-protection", "1; mode=block"))
    63 => Some((":status", "100"))
    64 => Some((":status", "204"))
    65 => Some((":status", "206"))
    66 => Some((":status", "302"))
    67 => Some((":status", "400"))
    68 => Some((":status", "403"))
    69 => Some((":status", "421"))
    70 => Some((":status", "425"))
    71 => Some((":status", "500"))
    72 => Some(("accept-language", ""))
    73 => Some(("access-control-allow-credentials", "FALSE"))
    74 => Some(("access-control-allow-credentials", "TRUE"))
    75 => Some(("access-control-allow-headers", "*"))
    76 => Some(("access-control-allow-methods", "get"))
    77 => Some(("access-control-allow-methods", "get, post, options"))
    78 => Some(("access-control-allow-methods", "options"))
    79 => Some(("access-control-expose-headers", "content-length"))
    80 => Some(("access-control-request-headers", "content-type"))
    81 => Some(("access-control-request-method", "get"))
    82 => Some(("access-control-request-method", "post"))
    83 => Some(("alt-svc", "clear"))
    84 => Some(("authorization", ""))
    85 =>
      Some(
        (
          "content-security-policy", "script-src 'none'; object-src 'none'; base-uri 'none'",
        ),
      )
    86 => Some(("early-data", "1"))
    87 => Some(("expect-ct", ""))
    88 => Some(("forwarded", ""))
    89 => Some(("if-range", ""))
    90 => Some(("origin", ""))
    91 => Some(("purpose", "prefetch"))
    92 => Some(("server", ""))
    93 => Some(("timing-allow-origin", "*"))
    94 => Some(("upgrade-insecure-requests", "1"))
    95 => Some(("user-agent", ""))
    96 => Some(("x-forwarded-for", ""))
    97 => Some(("x-frame-options", "deny"))
    98 => Some(("x-frame-options", "sameorigin"))
    _ => None
  }
}

///|
fn qpack_static_field(index : Int64) -> QpackField? {
  if index < 0L || index > 98L {
    return None
  }
  match qpack_static_get(index.to_int()) {
    Some((name, value)) =>
      Some({ name, value: @utf8.encode(value), sensitive: false, })
    None => None
  }
}

///|
fn qpack_static_find_exact(field : QpackField) -> Int {
  for index in 0..<99 {
    if qpack_static_get(index) is Some((name, value)) &&
      name == field.name &&
      @utf8.encode(value) == field.value {
      return index
    }
  }
  -1
}

///|
fn qpack_static_find_name(name : String) -> Int {
  for index in 0..<99 {
    if qpack_static_get(index) is Some((candidate, _)) && candidate == name {
      return index
    }
  }
  -1
}

///|
pub fn qpack_encode_static(
  fields : Array[QpackField],
  max_field_section_bytes? : Int = 64 * 1024,
  max_field_count? : Int = 100,
  use_huffman? : Bool = true,
) -> Result[Bytes, Http3Error] {
  if max_field_section_bytes < 0 || max_field_count < 0 {
    return Err(
      Http3LimitExceeded("QPACK field section", max_field_section_bytes),
    )
  }
  if fields.length() > max_field_count {
    return Err(Http3LimitExceeded("QPACK field count", max_field_count))
  }
  let output : Array[Byte] = [0, 0]
  let mut decoded_size = 0
  for field in fields {
    match qpack_validate_field(field) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    let size = qpack_field_size(field)
    if decoded_size > max_field_section_bytes ||
      size > max_field_section_bytes - decoded_size {
      return Err(
        Http3LimitExceeded(
          "QPACK decoded field section", max_field_section_bytes,
        ),
      )
    }
    decoded_size += size
    let sensitive = field.sensitive || qpack_sensitive_name(field.name)
    let exact = qpack_static_find_exact(field)
    if exact >= 0 && !sensitive {
      let encoded = qpack_encode_integer(6, exact.to_int64())
      encoded[0] = (encoded[0].to_int() | 0xc0).to_byte()
      qpack_append(output, encoded)
    } else {
      let name_index = qpack_static_find_name(field.name)
      if name_index >= 0 {
        let encoded = qpack_encode_integer(4, name_index.to_int64())
        encoded[0] = (encoded[0].to_int() |
        0x50 |
        (if sensitive { 0x20 } else { 0 })).to_byte()
        qpack_append(output, encoded)
      } else {
        let leading = 0x20 | (if sensitive { 0x10 } else { 0 })
        qpack_append(
          output,
          qpack_encode_string(
            @utf8.encode(field.name),
            3,
            0x08,
            leading,
            use_huffman,
          ),
        )
      }
      qpack_append(
        output,
        qpack_encode_string(field.value, 7, 0x80, 0, use_huffman),
      )
    }
    if output.length() > max_field_section_bytes {
      return Err(
        Http3LimitExceeded(
          "QPACK encoded field section", max_field_section_bytes,
        ),
      )
    }
  }
  Ok(Bytes::from_array(output))
}
