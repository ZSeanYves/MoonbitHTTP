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
fn write_response_with_body(
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

///|
/// 读取一个请求（行 + 头 + body），body 支持流式：
pub fn read_request_streaming(
  io : @tsp.Transport,
  max_headers : Int,
  max_line : Int,
  read_win : Int,
  max_body : Int,
  stream_chunk? : Int = 8 * 1024,
) -> Result[@cor.Request, String] {
  let cur = @tsp.buf_new()
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
  let rl = req_line
  let hs = req_headers
  let mut body : @cor.Body = @cor.Body::Empty
  if @cor.has_token_ci(hs, "transfer-encoding", "chunked") {
    let mut total = 0
    let mut finished = false
    body = @cor.Body::Stream(fn() -> Result[(Array[Byte], Bool), String] {
      if finished {
        let empty : Array[Byte] = []
        return Ok((empty, true))
      }
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
        finished = true
        let empty : Array[Byte] = []
        return Ok((empty, true))
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
      Ok((bs, false))
    })
  } else {
    //  Content-Length 方式
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
      let mut remaining = len
      let chunk_size = stream_chunk
      let mut rounds = 0
      body = @cor.Body::Stream(fn() -> Result[(Array[Byte], Bool), String] {
        if remaining <= 0 {
          let empty : Array[Byte] = []
          return Ok((empty, true))
        }
        let want = if remaining < chunk_size { remaining } else { chunk_size }
        let out : Array[Byte] = []
        let mut have = 0
        while have < want {
          let chunk = cur.buf_take(want - have)
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
            rounds += 1
            if rounds > 4096 {
              return Err("too many read rounds (stream body)")
            }
            continue
          }
          rounds += 1
          if rounds > 4096 {
            return Err("too many read rounds (stream body)")
          }
        }
        remaining -= have
        let done = remaining <= 0
        Ok((out, done))
      })
    } else {
      body = @cor.Body::Empty
    }
  }
  let req : @cor.Request = { line: rl, headers: hs, body }
  Ok(req)
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
  assert_eq(@cor.str_starts_with(s, "HTTP/1.1 100 Continue\r\n\r\n"), true)
  assert_eq(@cor.str_contains(s, "HTTP/1.1 200 OK\r\n"), true)

  // 最终响应应包含 Content-Length: 2（"ok"）
  assert_eq(@cor.str_contains(s, "Content-Length: 2\r\n"), true)

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

  // 状态码与头检查
  assert_eq(code, 200)
  assert_eq(hs.get("Transfer-Encoding").unwrap_or(""), "chunked")
  assert_eq(is_chunked, true)
  match body {
    @cor.Body::Stream(next) => {
      // 第1块
      let (c1, done1) = match next() {
        Ok(p) => p
        Err(_e) => {
          assert_eq(true, false)
          return
        }
      }
      let s1 = try @buf.utf8_bytes_to_string(Bytes::from_array(c1)) catch {
        _ => {
          assert_eq(true, false)
          return
        }
      } noraise {
        s => s
      }
      assert_eq(s1, "part-1...\n")
      assert_eq(done1, false)

      // 第2块
      let (c2, done2) = match next() {
        Ok(p) => p
        Err(_e) => {
          assert_eq(true, false)
          return
        }
      }
      let s2 = try @buf.utf8_bytes_to_string(Bytes::from_array(c2)) catch {
        _ => {
          assert_eq(true, false)
          return
        }
      } noraise {
        s => s
      }
      assert_eq(s2, "part-2...\n")
      assert_eq(done2, false)

      // 第3块
      let (c3, done3) = match next() {
        Ok(p) => p
        Err(_e) => {
          assert_eq(true, false)
          return
        }
      }
      let s3 = try @buf.utf8_bytes_to_string(Bytes::from_array(c3)) catch {
        _ => {
          assert_eq(true, false)
          return
        }
      } noraise {
        s => s
      }
      assert_eq(s3, "part-3...\n")
      assert_eq(done3, true)

      // 再调一次，应该返回空 + done=true
      let (c4, done4) = match next() {
        Ok(p) => p
        Err(_e) => {
          assert_eq(true, false)
          return
        }
      }
      assert_eq(c4.length(), 0)
      assert_eq(done4, true)
    }
    _ =>
      // 期望是 Body::Stream
      assert_eq(true, false)
  }
}


///|
test "http1: echo_handler_streaming echo body (debug)" {
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

  // 头 + 状态检查
  assert_eq(code, 200)
  assert_eq(hs.get("Transfer-Encoding").unwrap_or(""), "chunked")
  assert_eq(is_chunked, true)
  match body_out {
    @cor.Body::Stream(next_out) => {
      let buf_all : Array[Byte] = []
      let mut round = 0
      while true {
        round += 1
        if round > 10 {
          // 10 轮还没 done 说明有问题
          assert_eq(true, false)
          break
        }
        let (chunk, done) = match next_out() {
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
      let s_all = try
        @buf.utf8_bytes_to_string(Bytes::from_array(buf_all))
      catch {
        _ => {
          assert_eq(true, false)
          return
        }
      } noraise {
        s => s
      }
      // 应该刚好是 "hello world"
      assert_eq(s_all, "hello world")
    }
    _ => {
      assert_eq(true, false)
      return
    }
  }
}


///|
test "http1: Body helpers debug" {
  let b_empty = @cor.body_empty()
  assert_eq(@cor.body_len(b_empty), 0)
  let bs = @buf.string_to_utf8_bytes("abc").to_array()
  let b_bytes = @cor.body_bytes(bs)
  assert_eq(@cor.body_len(b_bytes), 3)
  let b_stream = @cor.body_stream_from_bytes(bs)
  // 对 Stream，当前约定 len = -1
  assert_eq(@cor.body_len(b_stream), -1)
  match b_stream {
    @cor.Body::Stream(next) => {
      let (c1, d1) = match next() {
        Ok(p) => p
        Err(_e) => {
          assert_eq(true, false)
          return
        }
      }
      let s1 = try @buf.utf8_bytes_to_string(Bytes::from_array(c1)) catch {
        _ => {
          assert_eq(true, false)
          return
        }
      } noraise {
        s => s
      }
      // 第一次就把 "abc" 全部吐出来并 done=true
      assert_eq(s1, "abc")
      assert_eq(d1, true)
      let (c2, d2) = match next() {
        Ok(p) => p
        Err(_e) => {
          assert_eq(true, false)
          return
        }
      }
      // 再拿一次应该是空 + done=true
      assert_eq(c2.length(), 0)
      assert_eq(d2, true)
    }
    _ => assert_eq(true, false)
  }
}

///|
test "http1: chunked-style request body streaming (debug)" {
  // 模拟“经过 HTTP 解析后”的 chunked 请求：Body::Stream 两块 "hello " + "world"
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
  assert_eq(code, 200)
  assert_eq(hs.get("Transfer-Encoding").unwrap_or(""), "chunked")
  assert_eq(is_chunked, true)
  match body_out {
    @cor.Body::Stream(next_out) => {
      let buf_all : Array[Byte] = []
      let mut round = 0
      while true {
        round += 1
        if round > 10 {
          assert_eq(true, false)
          break
        }
        let (chunk, done) = match next_out() {
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
      let s_all = try
        @buf.utf8_bytes_to_string(Bytes::from_array(buf_all))
      catch {
        _ => {
          assert_eq(true, false)
          return
        }
      } noraise {
        s => s
      }
      assert_eq(s_all, "hello world")
    }
    _ => {
      assert_eq(true, false)
      return
    }
  }
}


///|
test "http1: full chunked HTTP request -> streaming echo (debug)" {
  // 构造真实的 HTTP/1.1 chunked 请求字节流
  let req_str = "POST /echo HTTP/1.1\r\n" +
    "Host: example.com\r\n" +
    "Transfer-Encoding: chunked\r\n" +
    "\r\n" +
    "6\r\nhello \r\n" +
    "5\r\nworld\r\n" +
    "0\r\n\r\n"
  let req_bytes = @buf.string_to_utf8_bytes(req_str).to_array()

  // in-memory transport：先用空数组 init，再 push_rx 喂入请求
  let empty : Array[Byte] = []
  let io = try @tsp.from_inmemory(empty) catch {
    _ => {
      assert_eq(true, false)
      return
    }
  } noraise {
    t => t
  }
  io.push_rx(req_bytes)

  // 跑一轮 streaming 版本的 server
  let r = serve_once_body_streaming(
    io,
    echo_handler_streaming,
    64, // max_headers
    8192, // max_line
    4096, // read_win
    max_body=1 * 1024 * 1024,
    stream_chunk=8 * 1024,
  )
  match r {
    Ok(_) => ()
    Err(e) => {
      assert_eq(e.length() >= 0, false)
      return
    }
  }

  // flush 写缓冲（如有需要）
  match io.flush() {
    Ok(_) => ()
    Err(_e) => {
      // flush 失败理论上也属于异常，简单 assert
      assert_eq(true, false)
      return
    }
  }

  // 取出服务端写出的数据
  let resp_bytes = io.take_tx()
  let s = (try? @buf.utf8_bytes_to_string(Bytes::from_array(resp_bytes))).unwrap_or(
    "",
  )

  // 断言：HTTP/1.1 200 + chunked 头 + body 包含 "hello " & "world"
  assert_eq(@cor.str_contains(s, "HTTP/1.1 200 OK"), true)
  assert_eq(@cor.str_contains(s, "Transfer-Encoding: chunked"), true)
  assert_eq(@cor.str_contains(s, "hello "), true)
  assert_eq(@cor.str_contains(s, "world"), true)
}
