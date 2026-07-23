// RFC 7541 Appendix A static table, including all entries 1 through 61.

///|
fn hpack_static_get(idx : Int) -> (String, String)? {
  match idx {
    1 => Some((":authority", ""))
    2 => Some((":method", "GET"))
    3 => Some((":method", "POST"))
    4 => Some((":path", "/"))
    5 => Some((":path", "/index.html"))
    6 => Some((":scheme", "http"))
    7 => Some((":scheme", "https"))
    8 => Some((":status", "200"))
    9 => Some((":status", "204"))
    10 => Some((":status", "206"))
    11 => Some((":status", "304"))
    12 => Some((":status", "400"))
    13 => Some((":status", "404"))
    14 => Some((":status", "500"))
    15 => Some(("accept-charset", ""))
    16 => Some(("accept-encoding", "gzip, deflate"))
    17 => Some(("accept-language", ""))
    18 => Some(("accept-ranges", ""))
    19 => Some(("accept", ""))
    20 => Some(("access-control-allow-origin", ""))
    21 => Some(("age", ""))
    22 => Some(("allow", ""))
    23 => Some(("authorization", ""))
    24 => Some(("cache-control", ""))
    25 => Some(("content-disposition", ""))
    26 => Some(("content-encoding", ""))
    27 => Some(("content-language", ""))
    28 => Some(("content-length", ""))
    29 => Some(("content-location", ""))
    30 => Some(("content-range", ""))
    31 => Some(("content-type", ""))
    32 => Some(("cookie", ""))
    33 => Some(("date", ""))
    34 => Some(("etag", ""))
    35 => Some(("expect", ""))
    36 => Some(("expires", ""))
    37 => Some(("from", ""))
    38 => Some(("host", ""))
    39 => Some(("if-match", ""))
    40 => Some(("if-modified-since", ""))
    41 => Some(("if-none-match", ""))
    42 => Some(("if-range", ""))
    43 => Some(("if-unmodified-since", ""))
    44 => Some(("last-modified", ""))
    45 => Some(("link", ""))
    46 => Some(("location", ""))
    47 => Some(("max-forwards", ""))
    48 => Some(("proxy-authenticate", ""))
    49 => Some(("proxy-authorization", ""))
    50 => Some(("range", ""))
    51 => Some(("referer", ""))
    52 => Some(("refresh", ""))
    53 => Some(("retry-after", ""))
    54 => Some(("server", ""))
    55 => Some(("set-cookie", ""))
    56 => Some(("strict-transport-security", ""))
    57 => Some(("transfer-encoding", ""))
    58 => Some(("user-agent", ""))
    59 => Some(("vary", ""))
    60 => Some(("via", ""))
    61 => Some(("www-authenticate", ""))
    _ => None
  }
}

// Returns the first static-table index for a literal with an indexed name.

///|
fn hpack_static_find_name(name : String) -> Int {
  // Pseudo-headers.
  if name == ":authority" {
    return 1
  }
  if name == ":method" {
    return 2
  }
  if name == ":path" {
    return 4
  }
  if name == ":scheme" {
    return 6
  }
  if name == ":status" {
    return 8
  }

  // Regular headers use the first index for the given name.
  if name == "accept-charset" {
    return 15
  }
  if name == "accept-encoding" {
    return 16
  }
  if name == "accept-language" {
    return 17
  }
  if name == "accept-ranges" {
    return 18
  }
  if name == "accept" {
    return 19
  }
  if name == "access-control-allow-origin" {
    return 20
  }
  if name == "age" {
    return 21
  }
  if name == "allow" {
    return 22
  }
  if name == "authorization" {
    return 23
  }
  if name == "cache-control" {
    return 24
  }
  if name == "content-disposition" {
    return 25
  }
  if name == "content-encoding" {
    return 26
  }
  if name == "content-language" {
    return 27
  }
  if name == "content-length" {
    return 28
  }
  if name == "content-location" {
    return 29
  }
  if name == "content-range" {
    return 30
  }
  if name == "content-type" {
    return 31
  }
  if name == "cookie" {
    return 32
  }
  if name == "date" {
    return 33
  }
  if name == "etag" {
    return 34
  }
  if name == "expect" {
    return 35
  }
  if name == "expires" {
    return 36
  }
  if name == "from" {
    return 37
  }
  if name == "host" {
    return 38
  }
  if name == "if-match" {
    return 39
  }
  if name == "if-modified-since" {
    return 40
  }
  if name == "if-none-match" {
    return 41
  }
  if name == "if-range" {
    return 42
  }
  if name == "if-unmodified-since" {
    return 43
  }
  if name == "last-modified" {
    return 44
  }
  if name == "link" {
    return 45
  }
  if name == "location" {
    return 46
  }
  if name == "max-forwards" {
    return 47
  }
  if name == "proxy-authenticate" {
    return 48
  }
  if name == "proxy-authorization" {
    return 49
  }
  if name == "range" {
    return 50
  }
  if name == "referer" {
    return 51
  }
  if name == "refresh" {
    return 52
  }
  if name == "retry-after" {
    return 53
  }
  if name == "server" {
    return 54
  }
  if name == "set-cookie" {
    return 55
  }
  if name == "strict-transport-security" {
    return 56
  }
  if name == "transfer-encoding" {
    return 57
  }
  if name == "user-agent" {
    return 58
  }
  if name == "vary" {
    return 59
  }
  if name == "via" {
    return 60
  }
  if name == "www-authenticate" {
    return 61
  }
  0
}

// Variable-length integers with an N-bit prefix, per RFC 7541 section 5.1.

///|
fn decode_integer(
  buf : Array[Byte],
  pos : Int,
  n : Int,
) -> Result[(Int, Int), String] {
  if pos >= buf.length() {
    return Err("hpack int: OOB")
  }
  let prefix_max = (1 << n) - 1
  let first = buf[pos].to_int() & 0xFF
  let mut val = first & prefix_max
  let mut used = 1
  if val < prefix_max {
    return Ok((val, used))
  }
  let mut m = 0
  let mut i = pos + 1
  while i < buf.length() {
    let b = buf[i].to_int() & 0xFF
    val += (b & 0x7F) << m
    used += 1
    if (b & 0x80) == 0 {
      return Ok((val, used))
    }
    m += 7
    i += 1
    if used > 5_000 {
      return Err("hpack int: too long")
    }
  }
  Err("hpack int: truncated")
}

// String literals with the RFC 7541 section 5.2 Huffman flag in the high bit.

///|
fn decode_string(buf : Array[Byte], pos : Int) -> Result[(String, Int), String] {
  if pos >= buf.length() {
    return Err("hpack str: OOB")
  }
  let b = buf[pos].to_int() & 0xFF
  let huff = (b & 0x80) != 0

  // decode_integer masks the Huffman flag from the 7-bit length prefix.
  let (len, used1) = match decode_integer(buf, pos, 7) {
    Ok(t) => t
    Err(e) => return Err(e)
  }
  let start = pos + used1
  let end = start + len
  if end > buf.length() {
    return Err("hpack str: truncated")
  }
  let data = Bytes::from_array(buf)[start:end].to_owned().to_array()
  let raw = if huff {
    match hpack_huffman_decode(data) {
      Ok(x) => x
      Err(e) => return Err(e)
    }
  } else {
    data
  }
  let s = @utf8.decode(Bytes::from_array(raw)) catch { _ => "" }
  Ok((s, used1 + len))
}

// Encodes an integer with an N-bit prefix.

///|
fn encode_integer(n : Int, value : Int) -> Array[Byte] {
  let out : Array[Byte] = []
  let prefix_max = (1 << n) - 1
  if value < prefix_max {
    out.push(value.to_byte())
    return out
  }
  out.push(prefix_max.to_byte())
  let mut v = value - prefix_max
  while v >= 128 {
    out.push((v % 128 + 128).to_byte())
    v = v / 128
  }
  out.push((v & 0x7F).to_byte())
  out
}

// Encodes a string; callers opt into Huffman encoding explicitly.

///|
fn encode_string(s : String, use_huffman? : Bool = false) -> Array[Byte] {
  let raw = @utf8.encode(s).to_array()
  let (payload, hflag) = if use_huffman {
    match hpack_huffman_encode(raw) {
      Ok(x) =>
        // Validate the encoded form before emitting it.
        match hpack_huffman_decode(x) {
          Ok(_) => (x, true)
          Err(_) => (raw, false)
        }
      Err(_) => (raw, false)
    }
  } else {
    (raw, false)
  }
  let out = encode_integer(7, payload.length())
  out[0] = ((out[0].to_int() & 0x7F) | (if hflag { 0x80 } else { 0 })).to_byte()
  let mut i = 0
  while i < payload.length() {
    out.push(payload[i])
    i += 1
  }
  out
}
