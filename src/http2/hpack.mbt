// --- 静态表（RFC7541 Appendix A：1..61 全量） ---
pub fn hpack_static_get(idx : Int) -> (String, String)? {
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

// 用“名字”拿静态表中的最小索引**（用于 Literal-with-indexed-name）
fn hpack_static_find_name(name : String) -> Int {
  // 伪头
  if name == ":authority" { return 1 }
  if name == ":method"    { return 2 }
  if name == ":path"      { return 4 }
  if name == ":scheme"    { return 6 }
  if name == ":status"    { return 8 } // 多值就挑第一个

  // 普通头（挑该名字出现的最小索引）
  if name == "accept-charset"              { return 15 }
  if name == "accept-encoding"             { return 16 }
  if name == "accept-language"             { return 17 }
  if name == "accept-ranges"               { return 18 }
  if name == "accept"                      { return 19 }
  if name == "access-control-allow-origin" { return 20 }
  if name == "age"                         { return 21 }
  if name == "allow"                       { return 22 }
  if name == "authorization"               { return 23 }
  if name == "cache-control"               { return 24 }
  if name == "content-disposition"         { return 25 }
  if name == "content-encoding"            { return 26 }
  if name == "content-language"            { return 27 }
  if name == "content-length"              { return 28 }
  if name == "content-location"            { return 29 }
  if name == "content-range"               { return 30 }
  if name == "content-type"                { return 31 }
  if name == "cookie"                      { return 32 }
  if name == "date"                        { return 33 }
  if name == "etag"                        { return 34 }
  if name == "expect"                      { return 35 }
  if name == "expires"                     { return 36 }
  if name == "from"                        { return 37 }
  if name == "host"                        { return 38 }
  if name == "if-match"                    { return 39 }
  if name == "if-modified-since"           { return 40 }
  if name == "if-none-match"               { return 41 }
  if name == "if-range"                    { return 42 }
  if name == "if-unmodified-since"         { return 43 }
  if name == "last-modified"               { return 44 }
  if name == "link"                        { return 45 }
  if name == "location"                    { return 46 }
  if name == "max-forwards"                { return 47 }
  if name == "proxy-authenticate"          { return 48 }
  if name == "proxy-authorization"         { return 49 }
  if name == "range"                       { return 50 }
  if name == "referer"                     { return 51 }
  if name == "refresh"                     { return 52 }
  if name == "retry-after"                 { return 53 }
  if name == "server"                      { return 54 }
  if name == "set-cookie"                  { return 55 }
  if name == "strict-transport-security"   { return 56 }
  if name == "transfer-encoding"           { return 57 }
  if name == "user-agent"                  { return 58 }
  if name == "vary"                        { return 59 }
  if name == "via"                         { return 60 }
  if name == "www-authenticate"            { return 61 }
  0
}


// 可变长整数（N 前缀位)
// 参照 RFC7541 §5.1
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

// 字符串（支持 Huffman：H=1）
// RFC7541 §5.2；最高位为 Huffman 标志
fn decode_string(buf : Array[Byte], pos : Int) -> Result[(String, Int), String] {
  if pos >= buf.length() {
    return Err("hpack str: OOB")
  }
  let b = buf[pos].to_int() & 0xFF
  let huff = (b & 0x80) != 0

  // 7-bit 前缀长度（decode_integer 内部会自动屏蔽掉 MSB）
  let (len, used1) = match decode_integer(buf, pos, 7) {
    Ok(t) => t
    Err(e) => return Err(e)
  }
  let start = pos + used1
  let end = start + len
  if end > buf.length() {
    return Err("hpack str: truncated")
  }
  let data = @cor.byte_slice(buf, start, end)
  let raw = if huff {
    match hpack_huff_decode(data) {
      Ok(x) => x
      Err(e) => return Err(e)
    }
  } else {
    data
  }
  let s = (try? @buf.utf8_bytes_to_string(Bytes::from_array(raw))).unwrap_or("")
  Ok((s, used1 + len))
}


// 主解码：把 header block bytes 解成数组（保持顺序）
pub fn hpack_decode_block(
  block : Array[Byte],
) -> Result[Array[HpackHeader], String] {
  let out : Array[HpackHeader] = []
  let mut pos = 0
  while pos < block.length() {
    let b = block[pos].to_int() & 0xFF
    if (b & 0x80) != 0 {
      // Indexed Header Field (1xxxxxxx)
      let (idx, used) = match decode_integer(block, pos, 7) {
        Ok(t) => t
        Err(e) => return Err(e)
      }
      pos += used
      match hpack_static_get(idx) {
        Some((n, v)) => out.push({ name: n, value: v })
        None =>
          return Err(
            "hpack: static index " + idx.to_string() + " not supported",
          )
      }
    } else if (b & 0xC0) == 0x40 {
      // Literal with Incremental Indexing (01xxxxxx) , 先当作 without indexing 处理（不进动态表）
      let (name, _, used_total) = match decode_header_name(block, pos, 6) {
        Ok(t) => t
        Err(e) => return Err(e)
      }
      pos += used_total
      let (val, used_v) = match decode_string(block, pos) {
        Ok(t) => t
        Err(e) => return Err(e)
      }
      pos += used_v
      out.push({ name, value: val })
    } else if (b & 0xF0) == 0x00 || (b & 0xF0) == 0x10 {
      // Literal without indexing (0000xxxx 或 0001xxxx)
      let (name, _, used_total) = match decode_header_name(block, pos, 4) {
        Ok(t) => t
        Err(e) => return Err(e)
      }
      pos += used_total
      let (val, used_v) = match decode_string(block, pos) {
        Ok(t) => t
        Err(e) => return Err(e)
      }
      pos += used_v
      out.push({ name, value: val })
    } else if (b & 0xE0) == 0x20 {
      // 我们不使用动态表，直接跳过并拒绝非零
      let (sz, used) = match decode_integer(block, pos, 5) {
        Ok(t) => t
        Err(e) => return Err(e)
      }
      pos += used
      if sz != 0 {
        return Err("hpack: dynamic table not supported")
      }
    } else {
      return Err("hpack: unsupported header representation: " + b.to_string())
    }
  }
  Ok(out)
}

fn decode_header_name(
  block : Array[Byte],
  pos : Int,
  n : Int, // prefix bits width (6 for 01xxxxxx, 4 for 000x)
) -> Result[(String, Int, Int), String] {
  let (idx, used1) = match decode_integer(block, pos, n) {
    Ok(t) => t
    Err(e) => return Err(e)
  }
  if idx == 0 {
    let (name, used2) = match decode_string(block, pos + used1) {
      Ok(t) => t
      Err(e) => return Err(e)
    }
    Ok((name, 0, used1 + used2))
  } else {
    match hpack_static_get(idx) {
      Some((n, _v)) => Ok((n, idx, used1))
      None =>
        Err("hpack: static name index " + idx.to_string() + " not supported")
    }
  }
}


// 编整数（N 前缀位）
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


// 编字符串：可选 Huffman（默认 false 以保持旧行为）
fn encode_string(s : String, use_huffman? : Bool = false) -> Array[Byte] {
  let raw = @buf.string_to_utf8_bytes(s).to_array()
  let (payload, hflag) = if use_huffman {
    match hpack_huff_encode(raw) {
      Ok(x) => {
        // 自校验：确保解码端可还原
        match hpack_huff_decode(x) {
          Ok(_) => (x, true)
          Err(_) => (raw, false)   // 回退
        }
      }
      Err(_) => (raw, false)       // 回退
    }
  } else {
    (raw, false)
  }
  let out = encode_integer(7, payload.length())
  out[0] = ((out[0].to_int() & 0x7F) | (if hflag {0x80} else {0})).to_byte()
  let mut i = 0
  while i < payload.length() { out.push(payload[i]); i += 1 }
  out
}


// 支持 Literal without indexing：name 用静态表索引或字面量,Huffman 可选
// 目前默认不启用 Huffman,调用方可选择 H=1
// 目前仅支持静态表索引；动态表未实现
pub fn hpack_encode_literal_noindex(
  name : String,
  value : String,
  use_huffman? : Bool = false,
) -> Array[Byte] {
  let out : Array[Byte] = []
  let idx = hpack_static_find_name(name)
  let use_huffman_name = use_huffman && idx == 0 // 只有字面量 name 才可能 Huffman
  let use_huffman_value = use_huffman // value 的策略直接继承外部开关
  if idx > 0 {
    // name 用静态表索引（不会走 Huffman）
    let ints = encode_integer(4, idx)
    let first = ints[0].to_int() & 0x0F
    out.push(first.to_byte())
    let mut i = 1
    while i < ints.length() {
      out.push(ints[i])
      i += 1
    }
  } else {
    // name 走字面量，可根据 use_huffman_name 选择 Huffman
    let ints = encode_integer(4, 0)
    out.push((ints[0].to_int() & 0x0F).to_byte())
    let mut i = 1
    while i < ints.length() {
      out.push(ints[i])
      i += 1
    }
    let nameb = encode_string(name, use_huffman=use_huffman_name)
    let mut j = 0
    while j < nameb.length() {
      out.push(nameb[j])
      j += 1
    }
  }

  // value 独立控制（但目前与外部同开关）
  let vb = encode_string(value, use_huffman=use_huffman_value)
  let mut k = 0
  while k < vb.length() {
    out.push(vb[k])
    k += 1
  }
  out
}




// 把 (name,value) 列表编码为一个 header block（最小编码：no-index, no-huffman）
pub fn hpack_encode_list_noindex(hs : Array[HpackHeader]) -> Array[Byte] {
  let out : Array[Byte] = []
  let mut i = 0
  while i < hs.length() {
    let item = hs[i]
    let part = hpack_encode_literal_noindex(item.name, item.value)
    let mut j = 0
    while j < part.length() {
      out.push(part[j])
      j += 1
    }
    i += 1
  }
  out
}

// 把 Map[String,String]（或伪头在前的 Array）封成 HEADERS(+CONTINUATION) 帧字节
// 传入的 `hs` 顺序为：伪头在前：:method, :path, :scheme, :authority
pub fn build_headers_frames_from_list(
  stream_id : Int,
  hs : Array[HpackHeader],
  end_stream : Bool,
  max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE,
) -> Array[Byte] {
  let block = hpack_encode_list_noindex(hs)
  build_headers_frames(stream_id, block, end_stream, max_frame_size~)
}
