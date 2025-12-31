// 直到读到一整行（不含 CRLF）
///|
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
        try @buf.utf8_bytes_to_string(Bytes::from_array(bytes)) catch {
          _ => return Err("invalid utf8 in line") // UTF-8 转换失败
        } noraise {
          s => return Ok(s) // 成功返回字符串
        }
      Err(_) => {
        let n = match read_once_into(cur, io, read_win) {
          Ok(n) => n
          Err(e) => return Err(e) 
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
  return Err("Unexpected error in while loop") 
}
// 读定长正文：优先消费 cur 中已缓冲的数据，不足再从 io 拉，直到凑够 n
///|
fn read_exact_bytes(
  cur : @tsp.BufCursor,
  io : @tsp.Transport,
  n : Int,
  read_win : Int,
) -> Result[Array[Byte], String] {
  let out : Array[Byte] = []
  let mut left = n
  // a) 先吃缓冲里的
  let avail0 = cur.buf_len()
  if avail0 > 0 {
    let take0 = if avail0 < left { avail0 } else { left }
    let chunk0 = cur.buf_take(take0)
    for b in chunk0 {
      out.push(b)
    }
    left -= take0
  }
  // b) 持续拉流补齐
  let mut rounds = 0
  while left > 0 {
    match read_once_into(cur, io, read_win) {
      Ok(m) => {
        if m == 0 {
          // 非阻塞传输下可能返回 0；若仍无数据可取则视为意外 EOF
          if cur.buf_len() == 0 {
            return Err("unexpected eof while reading fixed-length body")
          }
        }
        let avail = cur.buf_len()
        let take = if avail < left { avail } else { left }
        let chunk = cur.buf_take(take)
        for b in chunk {
          out.push(b)
        }
        left -= take
      }
      Err(e) => return Err(e)
    }
    rounds += 1
    if rounds > 4096 {
      return Err("too many read rounds (body)")
    }
  }
  Ok(out)
}


///|
/// 简单的 ASCII 子串工具：从 s[start..end) 切一段出来。
/// 这里假定 status line 只含 ASCII，直接按字节切。
fn ascii_substring(s : String, start : Int, end : Int) -> String {
  let bytes = @buf.string_to_utf8_bytes(s).to_array()
  let out_bytes : Array[Byte] = []
  let mut i = start
  while i < end && i < bytes.length() {
    out_bytes.push(bytes[i])
    i += 1
  }
  (try? @buf.utf8_bytes_to_string(Bytes::from_array(out_bytes))).unwrap_or("")
}

// 解析响应状态行：HTTP/1.1 200 OK
///|
/// 解析响应状态行：HTTP/1.1 200 OK
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

  // 找到前两个空格的位置：
  //   [0 .. first_space)     -> version
  //   [first_space+1 .. second_space) -> code_str
  //   [second_space+1 .. end) -> reason
  let mut first_space = -1
  let mut second_space = -1
  let mut i = 0
  while i < s.length() {
    if s[i] == ' ' {
      if first_space < 0 {
        first_space = i
      } else {
        second_space = i
        break
      }
    }
    i += 1
  }
  if first_space < 0 || second_space < 0 {
    return Err("malformed status line: " + s)
  }

  let version = ascii_substring(s, 0, first_space)

  // 解析 code_str -> Int
  let mut code : Int = 0
  let mut j = first_space + 1
  while j < second_space {
    let ch = s[j]
    if ch < 48 || ch > 57 { // '0'..'9'
      return Err("invalid status code in line: " + s)
    }
    code = code * 10 + (ch.to_int() - 48)
    j += 1
  }

  // reason 子串
  let reason = if second_space + 1 < s.length() {
    ascii_substring(s, second_space + 1, s.length())
  } else {
    ""
  }
  Ok({ version, code, reason })
}


// 读取 chunked 响应体（合并为 Bytes；忽略 trailers 的键值解析，最小实现）
///|
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

// 按 EOF 读满（带上限/轮次保护），优先吃缓冲，再从 io 拉 
///|
fn read_body_to_eof(
  cur : @tsp.BufCursor,
  io : @tsp.Transport,
  read_win : Int,
  max_body : Int,
) -> Result[Array[Byte], String] {
  let out : Array[Byte] = []

  // 先拿走缓冲里已有的数据
  let avail0 = cur.buf_len()
  if avail0 > 0 {
    let chunk0 = cur.buf_take(avail0)
    for b in chunk0 {
      out.push(b)
    }
  }
  let mut rounds = 0
  while out.length() <= max_body {
    match read_once_into(cur, io, read_win) {
      Ok(n) => {
        if n == 0 {
          if cur.buf_len() == 0 {
            break
          } // 视为结束
        }
        let avail = cur.buf_len()
        if avail > 0 {
          let chunk = cur.buf_take(avail)
          for b in chunk {
            out.push(b)
          }
        }
      }
      Err(e) => {
        if e == "eof" || e == "Eof" {
          break
        }
        return Err(e)
      }
    }
    rounds += 1
    if rounds > 4096 {
      return Err("too many read rounds (eof-body)")
    }
  }
  if out.length() > max_body {
    return Err("response body too large")
  }
  Ok(out)
}

// ---------- 主逻辑 ----------
///|
fn read_response(
  io : @tsp.Transport,
  max_headers : Int,
  max_line : Int,
  read_win : Int,
  max_body : Int,
  enable_eof_fallback? : Bool = false,
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

  // —— 无消息体状态码：1xx / 204 / 304 ——
  let code = c.code
  let status_no_body = (code >= 100 && code < 200) || code == 204 || code == 304
  if status_no_body {
    let status : @cor.Status = { code: c.code, reason: c.reason }
    return Ok({ status, headers, body: @cor.Body::Empty })
  }
  let mut te = match @cor.get_ci(headers, "transfer-encoding") {
    Some(v) => v
    None => ""
  }
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
    // chunked：用现成的 read_chunked_body（内部也会增量拉流）
    let bs = match read_chunked_body(cur, io, read_win, max_line, max_body) {
      Ok(b) => b
      Err(e) => return Err(e)
    }
    body = @cor.Body::Bytes(bs)
  } else {
    let len_str = match @cor.get_ci(headers, "content-length") {
      Some(v) => v
      None => ""
    }
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
      // —— 可选：无 CL/TE 时按 EOF 读取（默认关闭） ——
    } else if enable_eof_fallback {
      let bs = match read_body_to_eof(cur, io, read_win, max_body) {
        Ok(b) => b
        Err(e) => return Err(e)
      }
      if bs.length() > 0 {
        body = @cor.Body::Bytes(bs)
      } else {
        body = @cor.Body::Empty
      }
    }
  }
  let status : @cor.Status = { code: c.code, reason: c.reason }
  Ok({ status, headers, body })
}


///|
/// 流式读取响应：
fn read_response_streaming(
  io : @tsp.Transport,
  max_headers : Int,
  max_line : Int,
  read_win : Int,
  max_body : Int,
  stream_chunk? : Int = 8 * 1024,
  enable_eof_fallback? : Bool = false,
) -> Result[@cor.Response, String] {
  let cur = @tsp.buf_new()

  // —— 状态行 —— 
  let c = match parse_status_line_streaming(cur, io, read_win, max_line) {
    Ok(t) => t
    Err(e) => return Err(e)
  }

  // —— 头部 —— 
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

  // —— 无消息体状态码：1xx / 204 / 304 ——
  let code = c.code
  let status_no_body = (code >= 100 && code < 200) || code == 204 || code == 304
  if status_no_body {
    let status : @cor.Status = { code: c.code, reason: c.reason }
    return Ok({ status, headers, body: @cor.Body::Empty })
  }

  // —— Transfer-Encoding 归一化为小写 —— 
  let mut te = match @cor.get_ci(headers, "transfer-encoding") {
    Some(v) => v
    None => ""
  }
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

  // —— chunked：仍然一次性读完（后续可以再升级为 streaming chunked 解码） —— 
  if te == "chunked" || (te.length() > 0 && te.find("chunked") != None) {
    let bs = match read_chunked_body(cur, io, read_win, max_line, max_body) {
      Ok(b) => b
      Err(e) => return Err(e)
    }
    body = @cor.Body::Bytes(bs)
  } else {
    // —— Content-Length —— 
    let len_str = match @cor.get_ci(headers, "content-length") {
      Some(v) => v
      None => ""
    }
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

      // 真正 streaming：不一次性读完，而是返回 Body::Stream
      let mut remaining = len
      let chunk_sz = stream_chunk
      let mut rounds = 0
      body = @cor.Body::Stream(fn() -> Result[(Array[Byte], Bool), String] {
        if remaining <= 0 {
          let empty : Array[Byte] = []
          return Ok((empty, true))
        }
        let want = if remaining < chunk_sz { remaining } else { chunk_sz }
        let out : Array[Byte] = []
        let mut have = 0
        while have < want {
          // 先吃 BufCursor 内已缓存数据
          let chunk = cur.buf_take(want - have)
          if chunk.length() > 0 {
            let mut j = 0
            while j < chunk.length() {
              out.push(chunk[j])
              j += 1
            }
            have += chunk.length()
            continue
          }

          // 没有缓存数据，从底层 Transport 拉
          let n = match read_once_into(cur, io, read_win) {
            Ok(n) => n
            Err(e) => return Err(e)
          }
          if n == 0 {
            // 非阻塞场景可能返回 0，避免死循环
            rounds += 1
            if rounds > 4096 {
              return Err("too many read rounds (stream-body)")
            }
            continue
          }
          rounds += 1
          if rounds > 4096 {
            return Err("too many read rounds (stream-body)")
          }
        }
        remaining -= have
        let done = remaining <= 0
        Ok((out, done))
      })
    } else if enable_eof_fallback {
      let bs = match read_body_to_eof(cur, io, read_win, max_body) {
        Ok(b) => b
        Err(e) => return Err(e)
      }
      if bs.length() > 0 {
        body = @cor.Body::Bytes(bs)
      } else {
        body = @cor.Body::Empty
      }
    } else {
      body = @cor.Body::Empty
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
) -> Result[@cor.Response, @cor.Herror] {
  ignore(@cor.write_ascii(io, "GET " + target + " HTTP/1.1\r\n"))
  ignore(@cor.write_ascii(io, "Host: " + host + "\r\n"))
  for k in extra_headers.keys() {
    let v = extra_headers.get(k).unwrap_or("")
    ignore(@cor.write_ascii(io, k + ": " + v + "\r\n"))
  }
  ignore(@cor.write_ascii(io, "Connection: close\r\n\r\n"))

  match read_response(
    io,
    limits.max_headers,
    limits.max_line,
    limits.read_win,
    limits.max_body,
  ) {
    Ok(resp) => Ok(resp)
    Err(e) => Err(@cor.err_proto("http1 client GET: " + e))
  }
}


///|
/// 流式版 GET：
pub fn get_streaming(
  io : @tsp.Transport,
  target : String,
  host : String,
  extra_headers : Map[String, String],
  limits : @cor.Limits,
  stream_chunk? : Int = 8 * 1024,
  enable_eof_fallback? : Bool = false,
) -> Result[@cor.Response, @cor.Herror] {
  ignore(@cor.write_ascii(io, "GET " + target + " HTTP/1.1\r\n"))
  ignore(@cor.write_ascii(io, "Host: " + host + "\r\n"))
  for k in extra_headers.keys() {
    let v = extra_headers.get(k).unwrap_or("")
    ignore(@cor.write_ascii(io, k + ": " + v + "\r\n"))
  }
  ignore(@cor.write_ascii(io, "Connection: close\r\n\r\n"))

  match read_response_streaming(
    io,
    limits.max_headers,
    limits.max_line,
    limits.read_win,
    limits.max_body,
    stream_chunk~,
    enable_eof_fallback~,
  ) {
    Ok(resp) => Ok(resp)
    Err(e) => Err(@cor.err_proto("http1 client GET streaming: " + e))
  }
}



///|
pub fn post(
  io : @tsp.Transport,
  target : String,
  host : String,
  extra_headers : Map[String, String],
  body : Array[Byte],
  content_type : String,
  limits : @cor.Limits,
) -> Result[@cor.Response, @cor.Herror] {
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

  try io.write_all(body) catch {
    _ => return Err(@cor.err_io("http1 client POST: write body failed"))
  } noraise {
    _ => ()
  }

  match read_response(
    io,
    limits.max_headers,
    limits.max_line,
    limits.read_win,
    limits.max_body,
  ) {
    Ok(resp) => Ok(resp)
    Err(e) => Err(@cor.err_proto("http1 client POST: " + e))
  }
}


// ---------- 测试 ----------
// Tools

// 测试：GET 请求并解析固定长度响应

///|
test "client: GET — parse fixed-length response & verify written request" {
  // 预置服务端响应（固定 Content-Length = 5）
  let resp_str = "HTTP/1.1 200 OK\r\n" +
    "Content-Type: text/plain\r\n" +
    "Content-Length: 5\r\n" +
    "\r\n" +
    "hello"
  let rx = @buf.string_to_utf8_bytes(resp_str).to_array()
  let io = try @tsp.from_inmemory(rx) catch {
    _ => {
      let a = true
      assert_eq(a, false)
      return
    }
  } noraise {
    t => t
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
      assert_eq(@cor.error_to_string(e).length() >= 0, false)
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
  assert_eq(@cor.str_starts_with(txs, "GET /index.html HTTP/1.1\r\n"), true)
  assert_eq(@cor.str_contains(txs, "Host: example.com\r\n"), true)
  assert_eq(@cor.str_contains(txs, "\r\n\r\n"), true)
}

// 测试：GET 请求并解析 chunked 响应

///|
test "client: GET — parse chunked response" {
  // 预置服务端响应（chunked：5\r\nhello\r\n0\r\n\r\n）
  let resp_str = "HTTP/1.1 200 OK\r\n" +
    "Content-Type: text/plain\r\n" +
    "Transfer-Encoding: chunked\r\n" +
    "\r\n" +
    "5\r\nhello\r\n0\r\n\r\n"
  let rx = @buf.string_to_utf8_bytes(resp_str).to_array()
  let io = try @tsp.from_inmemory(rx) catch {
    _ => {
      let a = true
      assert_eq(a, false)
      return
    }
  } noraise {
    t => t
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
      assert_eq(@cor.error_to_string(e).length() >= 0, false)
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

///|
test "client: POST — sends body & parses fixed-length response" {
  // 服务端预置响应（"ok"）
  let resp_str = "HTTP/1.1 200 OK\r\n" +
    "Content-Type: text/plain\r\n" +
    "Content-Length: 2\r\n" +
    "\r\n" +
    "ok"
  let rx = @buf.string_to_utf8_bytes(resp_str).to_array()
  let io = try @tsp.from_inmemory(rx) catch {
    _ => {
      let a = true
      assert_eq(a, false)
      return
    }
  } noraise {
    t => t
  }
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
    post(io, "/api", "example.com", extra, body, "application/json", limits) {
    Ok(r) => r
    Err(e) => {
      assert_eq(@cor.error_to_string(e).length() >= 0, false)
      return
    }
  }
  match resp.body {
    @cor.Body::Bytes(bs) => {
      let s = (try? @buf.utf8_bytes_to_string(Bytes::from_array(bs))).unwrap_or(
        "",
      )
      ////println("Response body: " + s)
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
  assert_eq(@cor.str_starts_with(txs, "POST /api HTTP/1.1\r\n"), true)
  assert_eq(@cor.str_contains(txs, "Host: example.com\r\n"), true)
  assert_eq(@cor.str_contains(txs, "Content-Type: application/json\r\n"), true)
  assert_eq(@cor.str_contains(txs, "Content-Length: 7\r\n"), true) // {"a":1} 长度 7
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
  ////println("Position of separator: ")
  ////println(pos)
  assert_eq(pos >= 0, true)
  let a = @buf.string_to_utf8_bytes(txs).to_array()
  let body_sent = @cor.byte_slice(a, pos + sep.length(), a.length())
  let b = (try? @buf.utf8_bytes_to_string(Bytes::from_array(body_sent))).unwrap_or(
    "",
  )
  assert_eq(b, "{\"a\":1}")
}


///|
test "client: GET streaming — fixed-length response as stream" {
  // 服务端预置响应：Content-Length = 11, body = "hello world"
  let resp_str = "HTTP/1.1 200 OK\r\n" +
    "Content-Type: text/plain\r\n" +
    "Content-Length: 11\r\n" +
    "\r\n" +
    "hello world"
  let rx = @buf.string_to_utf8_bytes(resp_str).to_array()
  let io = try @tsp.from_inmemory(rx) catch {
    _ => {
      assert_eq(true, false)
      return
    }
  } noraise {
    t => t
  }
  let limits : @cor.Limits = {
    max_headers: 32,
    max_line: 1024,
    read_win: 4096,
    max_body: 1 * 1024 * 1024,
  }
  let extra : Map[String, String] = Map::new()

  // 使用 streaming 版 GET，指定较小的 stream_chunk，让它分多次吐出
  let resp = match
    get_streaming(
      io,
      "/",
      "example.com",
      extra,
      limits,
      stream_chunk=5,
      enable_eof_fallback=false,
    ) {
    Ok(r) => r
    Err(e) => {
      assert_eq(@cor.error_to_string(e).length() >= 0, false)
      return
    }
  }
  match resp.body {
    @cor.Body::Stream(next) => {
      let buf_all : Array[Byte] = []
      let mut round = 0
      while true {
        round += 1
        if round > 10 {
          // 不应该出现太多轮
          assert_eq(true, false)
          break
        }
        let (chunk, done) = match next() {
          Ok(p) => p
          Err(_e) => {
            assert_eq(true, false)
            return
          }
        }
        let mut i = 0
        while i < chunk.length() {
          buf_all.push(chunk[i])
          i += 1
        }
        if done {
          break
        }
      }
      let s = (try? @buf.utf8_bytes_to_string(Bytes::from_array(buf_all))).unwrap_or(
        "",
      )
      assert_eq(s, "hello world")
    }
    _ =>
      // 期望 streaming 版必须返回 Body::Stream
      assert_eq(true, false)
  }
}

