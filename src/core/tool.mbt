// 从字符串 s 中截取 [start, end) 区间，返回新字符串
pub fn str_slice(s:String, start:Int, end:Int) -> String {
  let mut out = ""
  let mut i = start
  while i < end && i < s.length() {
    out = out + s[i].to_string()
    i += 1
  }
  out
}

// 提取字节数组中的一个切片
pub fn byte_slice(bytes : Array[Byte], start : Int, end : Int) -> Array[Byte] {
  let lo = if start < 0 { 0 } else { start }
  let hi = if end > bytes.length() { bytes.length() } else { end }
  let hi2 = if hi < lo { lo } else { hi }
  let out : Array[Byte] = []
  let mut i = lo
  while i < hi2 {
    out.push(bytes[i])
    i += 1
  }
  out
}

pub fn copy_first(bs : Array[Byte], n : Int) -> Array[Byte] {
  let take = if n < 0 { 0 } else if n > bs.length() { bs.length() } else { n }
  let out : Array[Byte] = []
  let mut i = 0
  while i < take { out.push(bs[i]); i += 1 }
  out
}



// 将正整数转换为 16 进制字符串（小写），用于 chunked 块长度
pub fn _int_to_hex(n : Int) -> String {
  if n == 0 {
    return "0"
  }
  let table : Array[Byte] = @buf.string_to_utf8_bytes("0123456789abcdef").to_array()
  let out : Array[Byte] = []
  let mut m = n
  while m > 0 {
    let d = m % 16
    out.push(table[d])
    m = m / 16
  }
  // 把低位在前的数组翻转为正常顺序
  let mut i = 0
  let mut j = out.length() - 1
  while i < j {
    let tmp = out[i]
    out[i] = out[j]
    out[j] = tmp
    i += 1
    j -= 1
  }
  match (try? @buf.utf8_bytes_to_string(Bytes::from_array(out))) {
    Ok(s) => s
    Err(_) => "0"
  }
}

// 解析 16 进制数字（块大小）
pub fn _hex_to_int(s : String) -> Result[Int, String] {
  if s.length() == 0 {
    return Err("empty chunk size")
  }
  let bs = @buf.string_to_utf8_bytes(s).to_array()
  let mut i = 0
  let mut n : Int = 0
  while i < bs.length() {
    let d = bs[i].to_int()
    let v = if d >= 48 && d <= 57 {
      d - 48 // 0-9
    } else if d >= 65 && d <= 70 {
      d - 55 // A-F
    } else if d >= 97 && d <= 102 {
      d - 87 // a-f
    } else {
      return Err("invalid hex digit in chunk size: " + s)
    }
    n = n * 16 + v
    i += 1
  }
  Ok(n)
}

// 把 ASCII 字符串追加到 out
pub fn push_ascii(dst : Array[Byte], s : String) -> Array[Byte] {
  let bs = @buf.string_to_utf8_bytes(s).to_array()
  for b in bs {
    dst.push(b)
  }
  dst
}
// ASCII 字符串的便捷函数
pub fn write_ascii(io : @tsp.Transport, s : String) -> Result[Unit, String] {
  let bs = @buf.string_to_utf8_bytes(s).to_array()
  match (try? io.write_all(bs)) {
     Ok(_) => Ok(())
    Err(_) => Err("write ascii failed ")
  }
}


// 大小写不敏感获取单值（兼容当前 Map[String,String] 存储）
pub fn get_ci(headers : Map[String, String], key : String) -> String? {
  let want = norm_key(key)
  match headers.get(key) {
    Some(v) => return Some(v)
    None => ()
  }
  for k in headers.keys() {
    if norm_key(k) == want {
      return headers.get(k)
    }
  }
  None
}


// 判断空白：空格或水平制表符
fn is_ws(b : Byte) -> Bool {
  b == 0x20 || b == 0x09
}

// 在 arr 中查找第一个 b 的位置
pub fn find_byte(arr : Array[Byte], needle : Byte) -> Int? {
  let mut i = 0
  while i < arr.length() {
    if arr[i] == needle {
      return Some(i)
    }
    i += 1
  }
  None
}

// 左裁剪（空格/制表符）
pub fn ltrim_ascii(arr : Array[Byte]) -> Array[Byte] {
  let mut i = 0
  while i < arr.length() && is_ws(arr[i]) {
    i += 1
  }
  let out : Array[Byte] = []
  let mut j = i
  while j < arr.length() {
    out.push(arr[j])
    j += 1
  }
  out
}

// 右裁剪（空格/制表符）
pub fn rtrim_ascii(arr : Array[Byte]) -> Array[Byte] {
  if arr.length() == 0 {
    return arr
  }
  let mut end = arr.length()
  while end > 0 && is_ws(arr[end - 1]) {
    end -= 1
  }
  let out : Array[Byte] = []
  let mut i = 0
  while i < end {
    out.push(arr[i])
    i += 1
  }
  out
}

// UTF-8 字节转字符串（带错误信息）
pub fn bytes_to_utf8(arr : Array[Byte], ctx : String) -> Result[String, String] {
  match (try? @buf.utf8_bytes_to_string(Bytes::from_array(arr))) {
    Ok(s) => Ok(s)
    Err(_) => Err("invalid utf8 in " + ctx)
  }
}

// 去左右空白（仅空格与制表符）
pub fn trim_sp(s : String) -> String {
  let mut b = 0
  let mut e = s.length()
  while b < e && (s[b] == ' ' || s[b] == '\t') {
    b += 1
  }
  while e > b && (s[e - 1] == ' ' || s[e - 1] == '\t') {
    e -= 1
  }
  str_slice(s, b, e)
}


pub fn norm_key(key : String) -> String {
  trim_sp(key.to_lower())
}
// 是否需要在“写回”时剔除该头（仅当无正文状态码时生效）
pub fn _skip_hdr_in_no_body(key : String) -> Bool {
  let k = norm_key(key)        // to_lower + trim
  k == "content-length" || k == "transfer-encoding"
}


// 按 header 类型拆分值（CSV，但 Set-Cookie 例外）
pub fn split_header_list(norm_key_lc : String, raw : String) -> Array[String] {
  // RFC 6265: Set-Cookie 不能用逗号拆分（值内允许逗号）
  if norm_key_lc == "set-cookie" {
    let arr = Array::new()
    arr.push(trim_sp(raw))
    return arr
  }
  // 一般 CSV 拆分：按逗号分隔，逐个修剪
  let out = []
  let mut start = 0
  let bytes_len = raw.length()
  for i in 0..<bytes_len {
    if raw[i] == ',' {
      let seg = trim_sp(str_slice(raw, start, i))
      if seg.length() > 0 {
        out.push(seg)
      }
      start = i + 1
    }
  }
  let tail = trim_sp(str_slice(raw, start, bytes_len))
  if tail.length() > 0 {
    out.push(tail)
  }
  out
}




// 逗号分隔列表中查 token（大小写不敏感，容忍分号参数）
pub fn has_token_ci(
  headers : Map[String, String],
  key : String,
  token : String,
) -> Bool {
  let want = norm_key(token)
  match get_ci(headers, key) {
    None => false
    Some(vraw) => {
      let bs = @buf.string_to_utf8_bytes(vraw).to_array()
      let n = bs.length()
      let mut i = 0
      while i < n {
        // 跳过前导空白与逗号
        while i < n && (bs[i] == 0x20 || bs[i] == 0x09 || bs[i] == 44) {
          i += 1
        }
        if i >= n {
          break
        }

        // 在剩余字节中找 ';'(59) 与 ','(44) 的相对位置
        let rest = byte_slice(bs, i, n)
        let semi_rel = find_byte(rest, 59) // ';'
        let comma_rel = find_byte(rest, 44) // ','

        // 计算绝对下标；没有则用 n
        let semi = match semi_rel {
          Some(r) => i + r
          None => n
        }
        let comma = match comma_rel {
          Some(r) => i + r
          None => n
        }
        let end = if semi < comma { semi } else { comma }
        let token_bytes = byte_slice(bs, i, end)
        let token_str = match bytes_to_utf8(token_bytes, "header token") {
          Ok(s) => s
          Err(_) => "" // 非法 UTF-8 当空
        }
        let main = norm_key(token_str)
        if main.length() > 0 && main == want {
          return true
        }
        i = if comma < n { comma + 1 } else { n }
      }
      false
    }
  }
}




// 获取“可能多值”的头部所有值（逗号分隔；但对 Set-Cookie 不拆分）
pub fn get_all_ci(headers : Map[String, String], key : String) -> Array[String] {
  match get_ci(headers, key) {
    Some(val) => split_header_list(norm_key(key), val)
    None => Array::new()
  }
}

// 大小写不敏感解析 Content-Length（只接受纯数字，允许前后空白）
// 返回 Result 以便在调用处区分错误原因
pub fn parse_content_length(hs : Map[String, String]) -> Result[Int, String] {
  // 用公共大小写无关获取
  let raw = match get_ci(hs, "content-length") {
    Some(x) => x
    None => return Err("no content-length")
  }
  let s = trim_sp(raw)
  if s.length() == 0 {
    return Err("empty content-length")
  }

  // 逐字节检查 ‘0’..‘9’
  let bs = @buf.string_to_utf8_bytes(s).to_array()
  let mut i = 0
  let mut n : Int = 0
  while i < bs.length() {
    let b = bs[i].to_int()
    if b < 48 || b > 57 { // '0'..'9'
      return Err("invalid digit in content-length: " + s)
    }
    n = n * 10 + (b - 48)
    i += 1
  }
  Ok(n)
}

pub fn content_length_opt(hs : Map[String, String]) -> Int? {
  match parse_content_length(hs) {
    Ok(n) => Some(n)
    Err(_) => None
  }
}

// 输入整行（不含 CRLF），返回纯数字十六进制部分
pub fn parse_chunk_size_line(line : String) -> Result[Int, String] {
  let trimmed = trim_sp(line)
  let mut i = 0
  while i < trimmed.length() && trimmed[i] != ';' { i += 1 }
  let hex_part = trim_sp(str_slice(trimmed, 0, i))
  _hex_to_int(hex_part)
}



