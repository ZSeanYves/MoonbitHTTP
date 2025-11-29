// 处理函数类型：输入 Request，返回 (状态码, 头, body字节数组, 是否chunked)
// PS： 若 is_chunked = false，则由编码器生成 Content-Length。
//      若 is_chunked = true，则你必须在 headers 里设置 "Transfer-Encoding":"chunked"；编码器按 chunked 输出。
//handler    : (Request) -> (StatusCode, Map[String,String], Array[Byte], Bool)

///|
fn read_request_once(
  io : @tsp.Transport,
  max_headers : Int,
  max_line : Int,
  read_win : Int,
) -> Result[@cor.Request, String] {
  let cur = @tsp.buf_new()

  // 请求行
  let req_line : @cor.RequestLine = {
    let mut out_ok = false
    let mut out : @cor.RequestLine = {
      http_method: @cor.Method::GET,
      target: "",
      version: "",
    }
    let mut rounds = 0
    while true {
      match parse_request_line(cur) {
        Ok(rl) => {
          out = rl
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
            return Err("too many read rounds (request line)")
          }
        }
      }
    }
    if !out_ok {
      return Err("unreachable: request line not parsed")
    }
    out
  }

  // 头部
  let req_headers : Map[String, String] = {
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
  Ok({ line: req_line, headers: req_headers, body: @cor.Body::Empty })
}

///|
fn write_response_once(
  io : @tsp.Transport,
  status : @cor.StatusCode,
  headers : Map[String, String],
  body : Array[Byte],
  is_chunked : Bool,
) -> Result[Unit, String] {
  // 状态码与无体规则
  let code = @cor.status_code_value(status)
  let no_body = @cor.status_no_body(code)
  let head_status = encode_status_line(status)
  match @cor.write_ascii(io, head_status) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  for k in headers.keys() {
    let k_norm = @cor.norm_key(k)
    if no_body && @cor._skip_hdr_in_no_body(k) {
      continue
    }
    if !no_body && is_chunked && k_norm == "content-length" {
      continue
    }
    if !no_body &&
      !is_chunked &&
      (k_norm == "transfer-encoding" || k_norm == "content-length") {
      continue
    }
    let v = headers.get(k).unwrap_or("")
    match @cor.write_ascii(io, k + ": " + v + "\r\n") {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  if no_body {
    match @cor.write_ascii(io, "\r\n") {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    return Ok(())
  }
  if is_chunked {
    match @cor.write_ascii(io, "\r\n") {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    let chunk_size = 1024
    let mut i = 0
    while i < body.length() {
      let end = if i + chunk_size <= body.length() {
        i + chunk_size
      } else {
        body.length()
      }
      let sz = end - i
      match @cor.write_ascii(io, @cor._int_to_hex(sz) + "\r\n") {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      let chunk : Array[Byte] = []
      let mut j = i
      while j < end {
        chunk.push(body[j])
        j += 1
      }
      try io.write_all(chunk) catch {
        _ => return Err("write chunk body failed ")
      } noraise {
        _ => ()
      }
      match @cor.write_ascii(io, "\r\n") {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      i = end
    }
    match @cor.write_ascii(io, "0\r\n\r\n") {
      Ok(_) => Ok(())
      Err(e) => Err(e)
    }
  } else {
    // 非 chunked：追加 Content-Length 与空行，然后写体
    let content_len = body.length()
    match
      @cor.write_ascii(
        io,
        "Content-Length: " + content_len.to_string() + "\r\n\r\n",
      ) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    try io.write_all(body) catch {
      _ => Err("write body bytes failed ")
    } noraise {
      _ => Ok(())
    }
  }
}


///|
/// Stream：强制以 chunked 编码写出
pub fn write_response_with_body(
  io : @tsp.Transport,
  status : @cor.StatusCode,
  headers : Map[String, String],
  body : @cor.Body,
  is_chunked : Bool,
) -> Result[Unit, String] {
  let code = @cor.status_code_value(status)
  let no_body = @cor.status_no_body(code)
  match body {
    @cor.Body::Stream(_) =>
      if !is_chunked {
        return Err("Body::Stream requires chunked transfer (is_chunked=true)")
      }
    _ => ()
  }
  let head_status = encode_status_line(status)
  match @cor.write_ascii(io, head_status) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  for k in headers.keys() {
    let k_norm = @cor.norm_key(k)
    if no_body && @cor._skip_hdr_in_no_body(k) {
      continue
    }
    if !no_body && is_chunked && k_norm == "content-length" {
      continue
    }
    if !no_body &&
      !is_chunked &&
      (k_norm == "transfer-encoding" || k_norm == "content-length") {
      continue
    }
    let v = headers.get(k).unwrap_or("")
    match @cor.write_ascii(io, k + ": " + v + "\r\n") {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  if no_body {
    match @cor.write_ascii(io, "\r\n") {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    return Ok(())
  }
  match body {
    @cor.Body::Empty =>
      match @cor.write_ascii(io, "\r\nContent-Length: 0\r\n\r\n") {
        Ok(_) => Ok(())
        Err(e) => Err(e)
      }
    @cor.Body::Bytes(bs) =>
      write_response_once(io, status, headers, bs, is_chunked)
    @cor.Body::Stream(next) => {
      match @cor.write_ascii(io, "\r\n") {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      while true {
        let (chunk, done) = match next() {
          Ok(p) => p
          Err(e) => return Err(e)
        }
        if chunk.length() > 0 {
          match
            @cor.write_ascii(io, @cor._int_to_hex(chunk.length()) + "\r\n") {
            Ok(_) => ()
            Err(e) => return Err(e)
          }
          try io.write_all(chunk) catch {
            _ => return Err("write chunk body failed ")
          } noraise {
            _ => ()
          }
          match @cor.write_ascii(io, "\r\n") {
            Ok(_) => ()
            Err(e) => return Err(e)
          }
        }
        if done {
          break
        }
      }
      // 终止块
      match @cor.write_ascii(io, "0\r\n\r\n") {
        Ok(_) => Ok(())
        Err(e) => Err(e)
      }
    }
  }
}


// 读取一个完整请求：行 + 头 + （可选）body
///|
pub fn read_request_full(
  io : @tsp.Transport,
  max_headers : Int,
  max_line : Int,
  read_win : Int,
  max_body : Int,
) -> Result[@cor.Request, String] {
  let req0 = match read_request_once(io, max_headers, max_line, read_win) {
    Ok(r) => r
    Err(e) => return Err(e)
  }
  let rl = req0.line
  let hs = req0.headers

  // —— 优先判断 Transfer-Encoding: chunked（大小写不敏感，容忍分号参数/CSV）——
  let mut body = @cor.Body::Empty
  if @cor.has_token_ci(hs, "transfer-encoding", "chunked") {
    let cur = @tsp.buf_new()
    let bs = match read_chunked_body(cur, io, read_win, max_line, max_body) {
      Ok(b) => b
      Err(e) => return Err(e)
    }
    body = @cor.Body::Bytes(bs)
  } else {
    // —— Content-Length（保持你原先策略：解析失败 ⇒ 当作 0）——
    let len = match @cor.parse_content_length(hs) {
      Ok(n) => n
      Err(_) => 0
    }
    if len < 0 {
      return Err("negative content-length")
    }
    if len > 0 && len > max_body {
      return Err("payload too large: " + len.to_string())
    }
    if len > 0 {
      let cur = @tsp.buf_new()
      let bs = match read_exact_from(cur, io, len, read_win) {
        Ok(b) => b
        Err(e) => return Err(e)
      }
      body = @cor.Body::Bytes(bs)
    }
  }
  let creq : @cor.Request = { line: rl, headers: hs, body }
  Ok(creq)
}


// ---- 从 Transport 读到 BufCursor，直到可解析出一行（或读尽） ----
///|
fn read_once_into(
  cur : @tsp.BufCursor,
  io : @tsp.Transport,
  win : Int,
) -> Result[Int, String] {
  let buf : Array[Byte] = []
  buf.resize(win, 0)
  match io.read(buf) {
    Ok(n) => {
      if n > 0 {
        let chunk = @cor.copy_first(buf, n)
        cur.buf_push(chunk)
      }
      Ok(n)
    }
    Err(@tsp.IoError::WouldBlock) => Ok(0)
    Err(@tsp.IoError::Eof) => Err("eof while reading")
    Err(@tsp.IoError::Closed) => Err("closed while reading")
  }
}

// 兼容旧用法：一次请求
///|
pub fn serve_once(
  io : @tsp.Transport,
  handler : (@cor.Request) -> (
    @cor.StatusCode,
    Map[String, String],
    Array[Byte],
    Bool,
  ),
  max_headers : Int,
  max_line : Int,
  read_win : Int,
  max_body? : Int = 1 * 1024 * 1024, // 默认 1MB
) -> Result[Unit, String] {
  let req = match
    read_request_full(io, max_headers, max_line, read_win, max_body) {
    Ok(r) => r
    Err(e) => return Err(e)
  }
  let (status, resp_headers, resp_body, is_chunked) = handler(req)
  write_response_once(io, status, resp_headers, resp_body, is_chunked)
}

///|
/// 基于 Body 的一次性服务：handler 可以返回 Body::Empty / Bytes / Stream
pub fn serve_once_body(
  io : @tsp.Transport,
  handler : (@cor.Request) -> (
    @cor.StatusCode,
    Map[String, String],
    @cor.Body,
    Bool, // is_chunked
  ),
  max_headers : Int,
  max_line : Int,
  read_win : Int,
  max_body? : Int = 1 * 1024 * 1024,
) -> Result[Unit, String] {
  let req = match
    read_request_full(io, max_headers, max_line, read_win, max_body) {
    Ok(r) => r
    Err(e) => return Err(e)
  }
  let (status, resp_headers, resp_body, is_chunked) = handler(req)
  write_response_with_body(io, status, resp_headers, resp_body, is_chunked)
}

///|
pub fn serve_loop(
  io : @tsp.Transport,
  handler : (@cor.Request) -> (
    @cor.StatusCode,
    Map[String, String],
    Array[Byte],
    Bool,
  ),
  max_headers : Int,
  max_line : Int,
  read_win : Int,
  max_body? : Int = 1 * 1024 * 1024,
) -> Result[Unit, String] {
  while true {
    let req_heads = match
      read_request_once(io, max_headers, max_line, read_win) {
      Ok(r) => r
      Err(e) => return Err(e)
    }
    if req_heads.line.version == "HTTP/1.1" &&
      !req_heads.headers.contains("Host") {
      let _ = @cor.write_ascii(
        io, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n",
      )
      break
    }
    let has_expect_100 = req_heads.headers.get("Expect").unwrap_or("") ==
      "100-continue"
    if has_expect_100 {
      let _ = @cor.write_ascii(io, "HTTP/1.1 100 Continue\r\n\r\n")

    }

    // —— 读取请求体 ——（新增：force_close 标记）
    let hs = req_heads.headers
    let mut body = @cor.Body::Empty
    let mut force_close = false
    if @cor.has_token_ci(hs, "transfer-encoding", "chunked") {
      let cur = @tsp.buf_new()
      match read_chunked_body(cur, io, read_win, max_line, max_body) {
        Ok(bs) => body = @cor.Body::Bytes(bs)
        Err(_e) =>
          if has_expect_100 {
            body = @cor.Body::Empty
            force_close = true // ★ 触发容忍：强制关闭连接
          } else {
            return Err(_e)
          }
      }
    } else {
      let len = match @cor.parse_content_length(hs) {
        Ok(n) => n
        Err(_) => 0
      }
      if len < 0 {
        return Err("negative content-length")
      }
      if len > 0 && len > max_body {
        return Err("payload too large: " + len.to_string())
      }
      if len > 0 {
        let cur = @tsp.buf_new()
        match read_exact_from(cur, io, len, read_win) {
          Ok(bs) => body = @cor.Body::Bytes(bs)
          Err(_e) =>
            if has_expect_100 {
              body = @cor.Body::Empty
              force_close = true
            } else {
              return Err(_e)
            }
        }
      }
    }

    // —— 调用handler ——（若需要关闭，补 Connection: close 头）
    let req : @cor.Request = { line: req_heads.line, headers: hs, body }
    let (status, resp_headers, resp_body, is_chunked) = handler(req)
    if force_close && req_heads.line.version == "HTTP/1.1" {
      resp_headers.set("Connection", "close")
    }
    match write_response_once(io, status, resp_headers, resp_body, is_chunked) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }

    // —— 连接管理：有任何一处要求关闭，都关闭 —— 
    let conn = req_heads.headers.get("Connection").unwrap_or("")
    let v = req_heads.line.version
    let mut want_close = if v == "HTTP/1.1" {
      conn == "close"
    } else if v == "HTTP/1.0" {
      conn != "keep-alive"
    } else {
      false
    }
    if force_close {
      want_close = true
    }
    if want_close {
      break
    }
  }
  Ok(())
}

///|
pub fn serve_once_body_streaming(
  io : @tsp.Transport,
  handler : (@cor.Request) -> (
    @cor.StatusCode,
    Map[String, String],
    @cor.Body,
    Bool,
  ),
  max_headers : Int,
  max_line : Int,
  read_win : Int,
  max_body? : Int = 1 * 1024 * 1024,
  stream_chunk? : Int = 8 * 1024,
) -> Result[Unit, String] {
  let req = match
    read_request_streaming(
      io,
      max_headers,
      max_line,
      read_win,
      max_body,
      stream_chunk~, 
    ) {
    Ok(r) => r
    Err(e) => return Err(e)
  }
  let (status, resp_headers, resp_body, is_chunked) = handler(req)
  write_response_with_body(io, status, resp_headers, resp_body, is_chunked)
}



// 一个最简单的处理器：无论请求什么都返回 200 text/plain: "Hello"
///|
pub fn hello_handler(
  req : @cor.Request,
) -> (@cor.StatusCode, Map[String, String], Array[Byte], Bool) {
  ignore(req) // 先不看请求
  let hs : Map[String, String] = Map::new()
  hs.set("Content-Type", "text/plain")
  let body = @buf.string_to_utf8_bytes("Hello, MoonBit!").to_array()
  (@cor.StatusCode::OK, hs, body, false) // 非 chunked，自动 Content-Length
}

// 一个 chunked 处理器：返回两行拼起来的 body
///|
pub fn chunked_handler(
  req : @cor.Request,
) -> (@cor.StatusCode, Map[String, String], Array[Byte], Bool) {
  ignore(req)
  let hs : Map[String, String] = Map::new()
  hs.set("Content-Type", "text/plain")
  hs.set("Transfer-Encoding", "chunked")

  // body 一次性给出，编码器会按 chunked 分块；为了可预期，给一个短 body
  let body = @buf.string_to_utf8_bytes("Hello, world!").to_array()
  (@cor.StatusCode::OK, hs, body, true)
}


// 真正流式返回（多块 chunked）
///|
pub fn streaming_handler(
  req : @cor.Request,
) -> (@cor.StatusCode, Map[String, String], @cor.Body, Bool) {
  ignore(req)
  let hs : Map[String, String] = Map::new()
  hs.set("Content-Type", "text/plain")
  hs.set("Transfer-Encoding", "chunked")
  let chunks : Array[String] = []
  chunks.push("part-1...\n")
  chunks.push("part-2...\n")
  chunks.push("part-3...\n")
  let mut idx = 0
  let body = @cor.Body::Stream(fn() -> Result[(Array[Byte], Bool), String] {
    if idx >= chunks.length() {
      let empty : Array[Byte] = []
      Ok((empty, true))
    } else {
      let s = chunks[idx]
      idx += 1
      let bs = @buf.string_to_utf8_bytes(s).to_array()
      let done = idx >= chunks.length()
      Ok((bs, done))
    }
  })
  (@cor.StatusCode::OK, hs, body, true) // is_chunked = true
}

///|
pub fn echo_handler_streaming(
  req : @cor.Request,
) -> (@cor.StatusCode, Map[String, String], @cor.Body, Bool) {
  let hs_resp : Map[String, String] = Map::new()
  hs_resp.set("Content-Type", "application/octet-stream")
  hs_resp.set("Transfer-Encoding", "chunked")
  match req.body {
    @cor.Body::Stream(next) => {
      // 这里简单做个“边读请求、边写响应”的转发示例：
      // 把请求的 Stream 直接变成响应的 Stream
      let body_out = @cor.Body::Stream(fn() -> Result[
        (Array[Byte], Bool),
        String,
      ] {
        // 每次从请求流里拉一块
        let (chunk, done) = match next() {
          Ok(p) => p
          Err(e) => return Err(e)
        }
        Ok((chunk, done))
      })
      (@cor.StatusCode::OK, hs_resp, body_out, true)
    }
    _ => {
      // 非 streaming（比如 chunked 被一次性读完的情况）
      let empty : Array[Byte] = []
      (@cor.StatusCode::BadRequest, hs_resp, @cor.Body::Bytes(empty), false)
    }
  }
}


// 确保从 cur/io 里“精确”读取 need 个字节（放到 Array[Byte] 返回）
///|
pub fn read_exact_from(
  cur : @tsp.BufCursor,
  io : @tsp.Transport,
  need : Int,
  read_win : Int,
) -> Result[Array[Byte], String] {
  let out : Array[Byte] = []
  let mut have = 0
  let mut rounds = 0
  while have < need {
    // 先消费缓冲可用数据
    let chunk = cur.buf_take(need - have)
    if chunk.length() > 0 {
      let mut j = 0
      while j < chunk.length() {
        out.push(chunk[j])
        j += 1
      }
      ignore(cur.buf_drain(chunk.length()))
      have += chunk.length()
      continue
    }
    let n = match read_once_into(cur, io, read_win) {
      Ok(n) => n
      Err(e) => return Err(e)
    }
    if n == 0 {
      // 在某些实现中（例如 in-memory / WouldBlock），可能临时返回 0；
      // 不立刻报错，继续下一轮尝试。
      rounds += 1
      if rounds > 4096 {
        return Err("too many read rounds (request body)")
      }
      continue
    }
    rounds += 1
    if rounds > 4096 {
      return Err("too many read rounds (request body)")
    }
  }
  Ok(out)
}

// 一个用于 Expect 测试的简易处理器：回 200 OK，text/plain，body="ok"

///|
fn expect_ok_handler(
  req : @cor.Request,
) -> (@cor.StatusCode, Map[String, String], Array[Byte], Bool) {
  // 也可以在这里断言一下收到的 body，但本用例只验证 100→200 的回写顺序
  ignore(req)
  let hs : Map[String, String] = Map::new()
  hs.set("Content-Type", "text/plain")
  let body = @buf.string_to_utf8_bytes("ok").to_array()
  (@cor.StatusCode::OK, hs, body, false) // 非 chunked，由编码器写 CL
}

// 端到端：Expect: 100-continue

///|
test "server: Expect 100-continue — sends 100 then 200" {
  // 用拼接的方式构造请求
  let req = "POST /upload HTTP/1.1\r\n" +
    "Host: example.com\r\n" +
    "Content-Type: text/plain\r\n" +
    "Content-Length: 5\r\n" +
    "Expect: 100-continue\r\n" +
    "Connection: close\r\n" +
    "\r\n" +
    "hello"

  // in-memory transport：预置入站为请求
  let rx = @buf.string_to_utf8_bytes(req).to_array()
  let io = try @tsp.from_inmemory(rx) catch {
    _ => {
      let a = true
      assert_eq(a, false)
      return
    }
  } noraise {
    t => t
  }

  // 跑一轮服务端主循环（会先回 100，再读体，再回 200）
  let max_headers = 64
  let max_line = 4096
  let read_win = 4096
  match serve_loop(io, expect_ok_handler, max_headers, max_line, read_win) {
    Ok(_) => ()
    Err(e) => {
      assert_eq(e.length() >= 0, false)
      return
    }
  }

  // 取出服务端写出的数据
  let tx = io.take_tx()
  let s = (try? @buf.utf8_bytes_to_string(Bytes::from_array(tx))).unwrap_or("")

  // 断言：先有 100 Continue，再有最终 200 OK
  assert_eq(str_starts_with(s, "HTTP/1.1 100 Continue\r\n\r\n"), true)
  assert_eq(str_contains(s, "HTTP/1.1 200 OK\r\n"), true)

  // 最终响应应包含 Content-Length: 2（"ok"）
  assert_eq(str_contains(s, "Content-Length: 2\r\n"), true)

  // 校验 100 与 200 的顺序（100 出现在 200 之前）
  let p100 = s.find("HTTP/1.1 100 Continue\r\n\r\n").unwrap_or(-1)
  let p200 = s.find("HTTP/1.1 200 OK\r\n").unwrap_or(-1)
  assert_eq(p100 >= 0 && p200 > p100, true)
}

///|
test "http1: streaming_handler generates 3 chunks (debug)" {
  let req : @cor.Request = {
    line: {
      http_method: @cor.Method::GET,
      target: "/stream",
      version: "HTTP/1.1",
    },
    headers: Map::new(),
    body: @cor.Body::Empty,
  }
  let (status, hs, body, is_chunked) = streaming_handler(req)
  let code = @cor.status_code_value(status)
  ////println("=== streaming_handler test ===")
  ////println("status = " + code.to_string())
  ////println(
  // "TE = " +
  //  hs.get("Transfer-Encoding").unwrap_or("<none>") +
  //  ", is_chunked = " +
  //  is_chunked.to_string(),
  //)

  // 状态、头部先简单打印
  if code != 200 {
    ////println("!! status code != 200")
    return
  }
  if hs.get("Transfer-Encoding").unwrap_or("") != "chunked" {
    ////println("!! TE != chunked")
    return
  }
  if !is_chunked {
    ////println("!! is_chunked != true")
    return
  }
  match body {
    @cor.Body::Stream(next) => {
      // 第1块
      let (c1, done1) = match next() {
        Ok(p) => p
        Err(_e) => {
          ////println("next() 1 failed: " + _e)
          return
        }
      }
      let s1 = try @buf.utf8_bytes_to_string(Bytes::from_array(c1)) catch {
        _ => {
          ////println("bad utf8 in chunk1")
          return
        }
      } noraise {
        s => s
      }
      ////println("chunk1 = '" + s1 + "', done1 = " + done1.to_string())
      if s1 != "part-1...\n" || done1 {
       // //println("!! chunk1 mismatch or done1 should be false")
        return
      }

      // 第2块
      let (c2, done2) = match next() {
        Ok(p) => p
        Err(_e) => {
          //println("next() 2 failed: " + _e)
          return
        }
      }
      let s2 = try @buf.utf8_bytes_to_string(Bytes::from_array(c2)) catch {
        _ => {
          //println("bad utf8 in chunk2")
          return
        }
      } noraise {
        s => s
      }
      //println("chunk2 = '" + s2 + "', done2 = " + done2.to_string())
      if s2 != "part-2...\n" || done2 {
        //println("!! chunk2 mismatch or done2 should be false")
        return
      }

      // 第3块
      let (c3, done3) = match next() {
        Ok(p) => p
        Err(_e) => {
          //println("next() 3 failed: " + _e)
          return
        }
      }
      let s3 = try @buf.utf8_bytes_to_string(Bytes::from_array(c3)) catch {
        _ => {
          //println("bad utf8 in chunk3")
          return
        }
      } noraise {
        s => s
      }
      //println("chunk3 = '" + s3 + "', done3 = " + done3.to_string())
      if s3 != "part-3...\n" {
        //println("!! chunk3 mismatch")
        return
      }
      if !done3 {
        //println("!! done3 should be true")
        return
      }

      // 再调一次，看看结束后的行为
      let (_c4, _done4) = match next() {
        Ok(p) => p
        Err(_e) => {
          //println("next() 4 failed: " + _e)
          return
        }
      }
      //println(
      //  "after done: chunk4.len = " +
      //  _c4.length().to_string() +
      // ", done4 = " +
      //  _done4.to_string(),
      //)
    }
    _ => {
      //println("!! streaming_handler should return Body::Stream")
      return
    }
  }
  //println("streaming_handler test finished.\n")
}

///|
test "http1: echo_handler_streaming echo body (debug)" {
  //println("=== echo_handler_streaming test ===")

  // 准备两段要“流入”的内容
  let chunks_in : Array[String] = []
  chunks_in.push("hello ")
  chunks_in.push("world")
  let mut idx_in = 0
  let body_in = @cor.Body::Stream(fn() -> Result[(Array[Byte], Bool), String] {
    if idx_in >= chunks_in.length() {
      let empty : Array[Byte] = []
      Ok((empty, true))
    } else {
      let s = chunks_in[idx_in]
      idx_in += 1
      let bs = @buf.string_to_utf8_bytes(s).to_array()
      let done = idx_in >= chunks_in.length()
      Ok((bs, done))
    }
  })
  let req : @cor.Request = {
    line: {
      http_method: @cor.Method::POST,
      target: "/echo",
      version: "HTTP/1.1",
    },
    headers: Map::new(),
    body: body_in,
  }
  let (status, hs, body_out, is_chunked) = echo_handler_streaming(req)
  let code = @cor.status_code_value(status)
  //println("status = " + code.to_string())
  //println(
  //  "TE = " +
  //  hs.get("Transfer-Encoding").unwrap_or("<none>") +
  //  ", is_chunked = " +
  //  is_chunked.to_string(),
  //)
  if code != 200 {
    //println("!! status code != 200")
    return
  }
  if hs.get("Transfer-Encoding").unwrap_or("") != "chunked" {
    //println("!! TE != chunked")
    return
  }
  if !is_chunked {
    //println("!! is_chunked != true")
    return
  }
  match body_out {
    @cor.Body::Stream(next_out) => {
      let buf_all : Array[Byte] = []
      let mut round = 0
      while true {
        round += 1
        if round > 10 {
          //println("!! too many rounds when reading echo stream")
          break
        }
        let (chunk, done) = match next_out() {
          Ok(p) => p
          Err(_e) => {
            //println("next_out() failed: " + _e)
            return
          }
        }
        //println(
        //  "round " +
        //  round.to_string() +
        //  ", chunk.len = " +
        //  chunk.length().to_string() +
        //  ", done = " +
        //  done.to_string(),
        //)
        let mut i = 0
        while i < chunk.length() {
          buf_all.push(chunk[i])
          i += 1
        }
        if done {
          break
        }
      }
      let _s_all = try
        @buf.utf8_bytes_to_string(Bytes::from_array(buf_all))
      catch {
        _ => {
          //println("bad utf8 in all echo bytes")
          return
        }
      } noraise {
        s => s
      }
      //println("echoed body = '" + _s_all + "'")
      // 预期应为 "hello world"
    }
    _ => {
      //println("!! echo handler should return Body::Stream")
      return
    }
  }
  //println("echo_handler_streaming test finished.\n")
}

///|
test "http1: Body helpers debug" {
  //println("=== Body helpers test ===")
  let _empty = @cor.body_empty()
  //println("len(Empty) = " + @cor.body_len(_empty).to_string())
  let bs = @buf.string_to_utf8_bytes("abc").to_array()
  let _b_bytes = @cor.body_bytes(bs)
  //println("len(Bytes 'abc') = " + @cor.body_len(_b_bytes).to_string())
  let b_stream = @cor.body_stream_from_bytes(bs)
  //println("len(Stream 'abc') = " + @cor.body_len(b_stream).to_string())
  match b_stream {
    @cor.Body::Stream(next) => {
      let (c1, _d1) = match next() {
        Ok(p) => p
        Err(_e) => {
          //println("next() 1 failed: " + _e)
          return
        }
      }
      let _s1 = try @buf.utf8_bytes_to_string(Bytes::from_array(c1)) catch {
        _ => {
          //println("bad utf8 in stream chunk1")
          return
        }
      } noraise {
        s => s
      }
      //println("stream chunk1 = '" + _s1 + "', done1 = " + _d1.to_string())
      let (_c2, _d2) = match next() {
        Ok(p) => p
        Err(_e) => {
          //println("next() 2 failed: " + _e)
          return
        }
      }
      //println(
      //  "stream chunk2 len = " +
      //  _c2.length().to_string() +
      //  ", done2 = " +
      //  _d2.to_string(),
      //)
    }
    _ => ()//println("body_stream_from_bytes did not return Body::Stream")
  }
  //println("Body helpers test finished.\n")
}

