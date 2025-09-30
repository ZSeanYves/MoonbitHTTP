// 按键名大小写不敏感地从 headers 取值
fn get_header_lc(hs: Map[String, String], key_lc: String) -> String {
  for k in hs.keys() {
    // 低配 to-lower：只处理 ASCII 大写
    let kb = @buf.string_to_utf8_bytes(k).to_array()
    let out : Array[Byte] = []
    let mut i = 0
    while i < kb.length() {
      let c = kb[i].to_int()
      out.push(if c >= 65 && c <= 90 { (c + 32).to_byte() } else { kb[i] })
      i += 1
    }
    let k_lc = (try? @buf.utf8_bytes_to_string(Bytes::from_array(out))).unwrap_or(k)
    if k_lc == key_lc { return hs.get(k).unwrap_or("") }
  }
  ""
}

// 直到读到一整行（不含 CRLF）
fn read_line_until_ok(
  cur : @tsp.BufCursor,
  io : @tsp.Transport,
  read_win : Int,
  max_line : Int,
) -> Result[String, String] {
  let mut rounds = 0
  while true {
    match cur.buf_read_line_crlf(max_line) {
      Ok(bytes) =>
        match (try? @buf.utf8_bytes_to_string(Bytes::from_array(bytes))) {
          Ok(s) => return Ok(s) // 成功返回字符串
          Err(_) => return Err("invalid utf8 in line") // UTF-8 转换失败
        }
      Err(_) => {
        // 读取失败时，尝试再次读取
        let n = match read_once_into(cur, io, read_win) {
          Ok(n) => n
          Err(e) => return Err(e) // 读取发生错误时返回
        }
        ignore(n)
        rounds += 1
        if rounds > 1024 {
          // 如果读取尝试超过 1024 次，返回错误
          return Err("too many read rounds (line)")
        }
      }
    }
  }

  // Fallback in case of unexpected failure
  return Err("Unexpected error in while loop") // This will never be hit, but needed for type consistency
}



// 从 cur/io 精确读取 need 字节（可多次拉流）
fn read_exact_bytes(
  cur:@tsp.BufCursor, io:@tsp.Transport, need:Int, read_win:Int
) -> Result[Array[Byte], String] {
  let out : Array[Byte] = []
  let mut have = 0
  let mut rounds = 0
  while have < need {
    let chunk = cur.buf_take(need - have)
    if chunk.length() > 0 {
      let mut k = 0
      while k < chunk.length() { out.push(chunk[k]); k += 1 }
      have += chunk.length()
      continue
    }
    let n = match read_once_into(cur, io, read_win) {
      Ok(n) => n
      Err(e) => return Err(e)
    }
    if n == 0 {
      // 上层保证 need>0 时必须能读满；读不到则 EOF
      rounds += 1
      if rounds > 1024 { return Err("unexpected EOF while reading body") }
    }
  }
  Ok(out)
}

// 解析响应状态行：HTTP/1.1 200 OK
fn parse_status_line_streaming(
  cur : @tsp.BufCursor,
  io : @tsp.Transport,
  read_win : Int,
  max_line : Int,
) -> Result[@cor.StatusLine, String] {
  let s = match read_line_until_ok(cur, io, read_win, max_line) {
    Ok(x) => x
    Err(e) => return Err(e)
  }

  // 拆前两段：version、code；剩余为 reason
  let parts : Array[String] = []
  let mut start = 0
  let mut i = 0
  while i < s.length() {
    if s[i] == ' ' {
      parts.push(@cor.str_slice(s, start, i)) // 用 str_slice 替换 start..i
      start = i + 1
      if parts.length() == 2 {
        break
      }
    }
    i += 1
  }
  if parts.length() < 2 {
    return Err("malformed status line: " + s)
  }
  let version = parts[0]
  let code_str = parts[1]
  let reason = if start < s.length() {
    @cor.str_slice(s, start, s.length())
  } else {
    ""
  } // 用 str_slice 替换 start..s.length()

  // code_str -> Int
  let bs = @buf.string_to_utf8_bytes(code_str).to_array()
  let mut j = 0
  let mut code : Int = 0
  while j < bs.length() {
    let d = bs[j].to_int()
    if d < 48 || d > 57 {
      return Err("invalid status code: " + code_str)
    }
    code = code * 10 + (d - 48)
    j += 1
  }
  Ok({ version, code, reason })
}

// 读取 chunked 响应体（合并为 Bytes；忽略 trailers 的键值解析，最小实现）
fn read_chunked_body(
  cur : @tsp.BufCursor,
  io : @tsp.Transport,
  read_win : Int,
  max_line : Int,
  max_body : Int,
) -> Result[Array[Byte], String] {
  let out : Array[Byte] = [] // 用来存储所有块数据
  let mut total = 0
  while true {
    let size_line = match read_line_until_ok(cur, io, read_win, max_line) {
      Ok(x) => x
      Err(e) => return Err(e)
    }
    let size = match @cor._hex_to_int(size_line) {
      Ok(n) => n
      Err(e) => return Err(e)
    }
    if size == 0 {
      ignore(read_line_until_ok(cur, io, read_win, max_line))
      break
    }
    let bs = match read_exact_bytes(cur, io, size, read_win) {
      Ok(b) => b
      Err(e) => return Err(e)
    }
    ignore(read_line_until_ok(cur, io, read_win, max_line))
    total += bs.length()
    if total > max_body {
      return Err("response body too large")
    }
    let mut i = 0
    while i < bs.length() {
      out.push(bs[i])
      i += 1
    }
  }
  Ok(out)
}


// ---------- 主逻辑 ----------
pub fn read_response(
  io : @tsp.Transport,
  max_headers : Int,
  max_line : Int,
  read_win : Int,
  max_body : Int,
) -> Result[@cor.Response, String] {
  let cur = @tsp.buf_new()
  let c = match parse_status_line_streaming(cur, io, read_win, max_line) {
    Ok(t) => t
    Err(e) => return Err(e)
  }
  let headers : Map[String, String] = {
    let mut out_ok = false
    let mut out : Map[String, String] = Map::new()
    let mut rounds = 0
    while true {
      match parse_headers(cur, max_headers, max_line) {
        Ok(hs) => {
          out = hs
          out_ok = true
          break
        }
        Err(_) => {
          let n = match read_once_into(cur, io, read_win) {
            Ok(n) => n
            Err(e) => return Err(e)
          }
          ignore(n)
          rounds += 1
          if rounds > 1024 {
            return Err("too many read rounds (headers)")
          }
        }
      }
    }
    if !out_ok {
      return Err("unreachable: headers not parsed")
    }
    out
  }

  //    注意：只判断是否为 "chunked"（避免把原始分块文本当正文）
  let mut te = get_header_lc(headers, "transfer-encoding")
  {
    let bs = @buf.string_to_utf8_bytes(te).to_array()
    let out : Array[Byte] = []
    let mut i = 0
    while i < bs.length() {
      let c = bs[i].to_int()
      out.push(if c >= 65 && c <= 90 { (c + 32).to_byte() } else { bs[i] })
      i += 1
    }
    te = (try? @buf.utf8_bytes_to_string(Bytes::from_array(out))).unwrap_or(te)
  }
  let mut body = @cor.Body::Empty
  if te == "chunked" || (te.length() > 0 && te.find("chunked") != None) {
    // chunked：用你现成的 read_chunked_body（内部也会增量拉流）
    let bs = match read_chunked_body(cur, io, read_win, max_line, max_body) {
      Ok(b) => b
      Err(e) => return Err(e)
    }
    body = @cor.Body::Bytes(bs)
  } else {
    let len_str = get_header_lc(headers, "content-length")
    let len = if len_str.length() == 0 {
      0
    } else {
      let bss = @buf.string_to_utf8_bytes(len_str).to_array()
      let mut i = 0
      let mut n : Int = 0
      while i < bss.length() {
        let d = bss[i].to_int()
        if d < 48 || d > 57 {
          return Err("invalid Content-Length: " + len_str)
        }
        n = n * 10 + (d - 48)
        i += 1
      }
      n
    }
    if len > 0 {
      if len > max_body {
        return Err("response body too large")
      }
      let bs = match read_exact_bytes(cur, io, len, read_win) {
        Ok(b) => b
        Err(e) => return Err(e)
      }
      body = @cor.Body::Bytes(bs)
    }
  }
  let status : @cor.Status = { code: c.code, reason: c.reason }
  Ok({ status, headers, body })
}

// ---------- 简单 API ----------
pub fn get(
  io : @tsp.Transport,
  target : String,
  host : String,
  extra_headers : Map[String, String],
  limits : @cor.Limits,
) -> Result[@cor.Response, String] {
  ignore(@cor.write_ascii(io, "GET " + target + " HTTP/1.1\r\n"))
  ignore(@cor.write_ascii(io, "Host: " + host + "\r\n"))
  for k in extra_headers.keys() {
    let v = extra_headers.get(k).unwrap_or("")
    ignore(@cor.write_ascii(io, k + ": " + v + "\r\n"))
  }
  ignore(@cor.write_ascii(io, "Connection: close\r\n\r\n"))
  read_response(
    io,
    limits.max_headers,
    limits.max_line,
    limits.read_win,
    limits.max_body,
  )
}

pub fn post(
  io : @tsp.Transport,
  target : String,
  host : String,
  body : Array[Byte],
  content_type : String,
  extra_headers : Map[String, String],
  limits : @cor.Limits,
) -> Result[@cor.Response, String] {
  let len = body.length()
  ignore(@cor.write_ascii(io, "POST " + target + " HTTP/1.1\r\n"))
  ignore(@cor.write_ascii(io, "Host: " + host + "\r\n"))
  ignore(@cor.write_ascii(io, "Content-Type: " + content_type + "\r\n"))
  ignore(@cor.write_ascii(io, "Content-Length: " + len.to_string() + "\r\n"))
  for k in extra_headers.keys() {
    let v = extra_headers.get(k).unwrap_or("")
    ignore(@cor.write_ascii(io, k + ": " + v + "\r\n"))
  }
  ignore(@cor.write_ascii(io, "\r\n"))
  match (try? io.write_all(body)) {
    Ok(_) => ()
    Err(_) => return Err("write body failed")
  }
  read_response(
    io,
    limits.max_headers,
    limits.max_line,
    limits.read_win,
    limits.max_body,
  )
}



// ---------- 测试 ----------
// Tools
// 检查字符串是否以指定前缀开始
fn str_starts_with(s : String, prefix : String) -> Bool {
  if s.length() < prefix.length() {
    return false
  }
  for i in 0..<prefix.length() {
    if s[i] != prefix[i] {
      return false
    }
  }
  return true
}

// 检查字符串是否包含指定的子串
fn str_contains(s : String, needle : String) -> Bool {
  if needle.length() == 0 {
    return true
  }
  if needle.length() > s.length() {
    return false
  }
  for i in 0..<(s.length() - needle.length() + 1) {
    let mut match_found = true
    for j in 0..<needle.length() {
      if s[i + j] != needle[j] {
        match_found = false
        break
      }
    }
    if match_found {
      return true
    }
  }
  return false
}

// 测试：GET 请求并解析固定长度响应
test "client: GET — parse fixed-length response & verify written request" {
  // 预置服务端响应（固定 Content-Length = 5）
  let resp_str = "HTTP/1.1 200 OK\r\n" +
    "Content-Type: text/plain\r\n" +
    "Content-Length: 5\r\n" +
    "\r\n" +
    "hello"
  let rx = @buf.string_to_utf8_bytes(resp_str).to_array()
  let io = match (try? @tsp.from_inmemory(rx)) {
    Ok(t) => t
    Err(_) => {
      let a = true
      assert_eq(a, false)
      return
    }
  }
  // 客户端 GET
  let limits : @cor.Limits = {
    max_headers: 32,
    max_line: 1024,
    read_win: 4096,
    max_body: 1 * 1024 * 1024,
  }
  let extra : Map[String, String] = Map::new()
  let resp = match get(io, "/index.html", "example.com", extra, limits) {
    Ok(r) => r
    Err(e) => {
      assert_eq(e.length() >= 0, false)
      return
    }
  }
  match resp.body {
    @cor.Body::Bytes(bs) => {
      let s = (try? @buf.utf8_bytes_to_string(Bytes::from_array(bs))).unwrap_or(
        "",
      )
      assert_eq(s, "hello")
    }
    _ => {
      let a = true
      assert_eq(a, false)
    }
  }
  let tx = io.take_tx()
  let txs = (try? @buf.utf8_bytes_to_string(Bytes::from_array(tx))).unwrap_or(
    "",
  )
  assert_eq(str_starts_with(txs, "GET /index.html HTTP/1.1\r\n"), true)
  assert_eq(str_contains(txs, "Host: example.com\r\n"), true)
  assert_eq(str_contains(txs, "\r\n\r\n"), true)
}

// 测试：GET 请求并解析 chunked 响应
test "client: GET — parse chunked response" {
  // 预置服务端响应（chunked：5\r\nhello\r\n0\r\n\r\n）
  let resp_str = "HTTP/1.1 200 OK\r\n" +
    "Content-Type: text/plain\r\n" +
    "Transfer-Encoding: chunked\r\n" +
    "\r\n" +
    "5\r\nhello\r\n0\r\n\r\n"
  let rx = @buf.string_to_utf8_bytes(resp_str).to_array()
  let io = match (try? @tsp.from_inmemory(rx)) {
    Ok(t) => t
    Err(_) => {
      let a = true
      assert_eq(a, false)
      return
    }
  }
  let limits : @cor.Limits = {
    max_headers: 32,
    max_line: 1024,
    read_win: 4096,
    max_body: 1 * 1024 * 1024,
  }
  let extra : Map[String, String] = Map::new()
  let resp = match get(io, "/", "example.com", extra, limits) {
    Ok(r) => r
    Err(e) => {
      assert_eq(e.length() >= 0, false)
      return
    }
  }
  match resp.body {
    @cor.Body::Bytes(bs) => {
      let s = (try? @buf.utf8_bytes_to_string(Bytes::from_array(bs))).unwrap_or(
        "",
      )
      assert_eq(s, "hello")
    }
    _ => {
      let a = true
      assert_eq(a, false)
    }
  }
}

// 测试：POST 请求并解析固定长度响应
test "client: POST — sends body & parses fixed-length response" {
  // 服务端预置响应（"ok"）
  let resp_str = "HTTP/1.1 200 OK\r\n" +
    "Content-Type: text/plain\r\n" +
    "Content-Length: 2\r\n" +
    "\r\n" +
    "ok"
  let rx = @buf.string_to_utf8_bytes(resp_str).to_array()
  let io = match (try? @tsp.from_inmemory(rx)) {
    Ok(t) => t
    Err(_) => {
      let a = true
      assert_eq(a, false)
      return
    }
  }

  // 设置 limits（来自 cor.Limits）
  let limits : @cor.Limits = {
    max_headers: 32,
    max_line: 1024,
    read_win: 4096,
    max_body: 1 * 1024 * 1024,
  }
  let extra : Map[String, String] = Map::new()
  extra.set("User-Agent", "MoonbitHTTP/0.1")
  let body = @buf.string_to_utf8_bytes("{\"a\":1}").to_array()
  let resp = match
    post(io, "/api", "example.com", body, "application/json", extra, limits) {
    Ok(r) => r
    Err(e) => {
      assert_eq(e.length() >= 0, false)
      return
    }
  }
  match resp.body {
    @cor.Body::Bytes(bs) => {
      let s = (try? @buf.utf8_bytes_to_string(Bytes::from_array(bs))).unwrap_or(
        "",
      )
      //println("Response body: " + s)
      assert_eq(s, "ok")
    }
    _ => {
      let a = true
      assert_eq(a, false)
    }
  }

  // 调试：打印请求数据
  let tx = io.take_tx()
  let txs = (try? @buf.utf8_bytes_to_string(Bytes::from_array(tx))).unwrap_or(
    "",
  )
  let bytes = @buf.string_to_utf8_bytes(txs).to_array()
  assert_eq(str_starts_with(txs, "POST /api HTTP/1.1\r\n"), true)
  assert_eq(str_contains(txs, "Host: example.com\r\n"), true)
  assert_eq(str_contains(txs, "Content-Type: application/json\r\n"), true)
  assert_eq(str_contains(txs, "Content-Length: 7\r\n"), true) // {"a":1} 长度 7
  let sep = @buf.string_to_utf8_bytes("\r\n\r\n").to_array()
  let mut pos = -1
  let mut i = 0

  // 打印 byte-by-byte 比对过程
  while i + sep.length() <= bytes.length() {
    let slice = @cor.byte_slice(bytes, i, i + sep.length())
    if slice == sep {
      pos = i
      break
    }
    i += 1
  }

  // 检查分隔符位置是否找到
  //println("Position of separator: ")
  //println(pos)
  assert_eq(pos >= 0, true)
  let a = @buf.string_to_utf8_bytes(txs).to_array()
  let body_sent = @cor.byte_slice(a, pos + sep.length(), a.length())
  let b = (try? @buf.utf8_bytes_to_string(Bytes::from_array(body_sent))).unwrap_or(
    "",
  )
  assert_eq(b, "{\"a\":1}")
}
