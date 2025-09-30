// http1/handler.mbt — 读一次请求，调用用户处理函数，写回响应（最小闭环）

// 处理函数类型：输入 Request，返回 (状态码, 头, body字节数组, 是否chunked)
// PS： 若 is_chunked = false，则由编码器生成 Content-Length。
//      若 is_chunked = true，则你必须在 headers 里设置 "Transfer-Encoding":"chunked"；编码器按 chunked 输出。
//handler    : (Request) -> (StatusCode, Map[String,String], Array[Byte], Bool)

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
  Ok({ line: req_line, headers: req_headers , body: @cor.Body::Empty })
}


fn write_response_once(
  io : @tsp.Transport,
  status : @cor.StatusCode,
  headers : Map[String, String],
  body : Array[Byte],
  is_chunked : Bool,
) -> Result[Unit, String] {
  let content_len = if is_chunked { 0 } else { body.length() }
  let head = encode_status_line(status) + encode_headers(headers)
  match @cor.write_ascii(io, head) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  if content_len > 0 {
    match
      @cor.write_ascii(
        io,
        "Content-Length: " + content_len.to_string() + "\r\n\r\n",
      ) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    match (try? io.write_all(body)) {
      Ok(_) => Ok(())
      Err(_) => Err("write body bytes failed ")
    }
  } else {
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
      match (try? io.write_all(chunk)) {
        Ok(_) => ()
        Err(_) => return Err("write chunk body failed ")
      }
      match @cor.write_ascii(io, "\r\n") {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      i = end
    }
    @cor.write_ascii(io, "0\r\n\r\n")
  }
}

// 读取一个完整请求：行 + 头 + （可选）body
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

  // TODO: 
  // 是否声明了 Transfer-Encoding: chunked ？
  // 先不支持“分块请求体”，直接返回协议错误
  match hs.get("Transfer-Encoding") {
    Some(te) =>
      if te == "chunked" {
        return Err("request chunked body not supported yet")
      }
    None => ()
  }
  let len = match parse_content_length(hs) {
    Ok(n) => n
    Err(_) => 0
  }
  if len < 0 {
    return Err("negative content-length")
  }
  if len > 0 && len > max_body {
    return Err("payload too large: " + len.to_string())
  }
  let mut body = @cor.Body::Empty
  if len > 0 {
    let cur = @tsp.buf_new()
    let bs = match read_exact_from(cur, io, len, read_win) {
      Ok(b) => b
      Err(e) => return Err(e)
    }
    body = @cor.Body::Bytes(bs)
  }
  let creq : @cor.Request = { line: rl, headers: hs, body }
  Ok(creq)
}




// ---- 从 Transport 读到 BufCursor，直到可解析出一行（或读尽） ----
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
pub fn serve_once(
  io : @tsp.Transport,
  handler : (@cor.Request) -> (@cor.StatusCode, Map[String, String], Array[Byte], Bool),
  max_headers : Int,
  max_line : Int,
  read_win : Int,
  max_body~ : Int = 1 * 1024 * 1024, // 默认 1MB
) -> Result[Unit, String] {
  let req = match read_request_full(io, max_headers, max_line, read_win, max_body) {
    Ok(r) => r
    Err(e) => return Err(e)
  }
  let (status, resp_headers, resp_body, is_chunked) = handler(req)
  write_response_once(io, status, resp_headers, resp_body, is_chunked)
}

// 持久连接循环：默认 keep-alive，支持 Connection: close；HTTP/1.1 要求 Host
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
  max_body? : Int = 1 * 1024 * 1024, // 默认 1MB
) -> Result[Unit, String] {
  while true {
    let req = match
      read_request_full(io, max_headers, max_line, read_win, max_body) {
      Ok(r) => r
      Err(e) => return Err(e)
    }
    if req.line.version == "HTTP/1.1" && !req.headers.contains("Host") {
      let _ = @cor.write_ascii(
        io, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n",
      )
      break
    }
    if req.headers.get("Expect").unwrap_or("") == "100-continue" {
      let _ = @cor.write_ascii(io, "HTTP/1.1 100 Continue\r\n\r\n")

    }
    let (status, resp_headers, resp_body, is_chunked) = handler(req)
    match write_response_once(io, status, resp_headers, resp_body, is_chunked) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    let conn = req.headers.get("Connection").unwrap_or("")
    let v = req.line.version
    let want_close = if v == "HTTP/1.1" {
      conn == "close"
    } else if v == "HTTP/1.0" {
      conn != "keep-alive" // 1.0 默认关闭
    } else {
      false
    }
    if want_close {
      break
    }
  }
  Ok(())
}


// 一个最简单的处理器：无论请求什么都返回 200 text/plain: "Hello"
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



// 解析十进制 Content-Length（只接受纯数字）
pub fn parse_content_length(hs : Map[String, String]) -> Result[Int, String] {
  let s = match hs.get("Content-Length") {
    Some(x) => x
    None => return Err("no content-length")
  }
  if s.length() == 0 {
    return Err("empty content-length")
  }
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

// 确保从 cur/io 里“精确”读取 need 个字节（放到 Array[Byte] 返回）
pub fn read_exact_from(
  cur : @tsp.BufCursor,
  io : @tsp.Transport,
  need : Int,
  read_win : Int,
) -> Result[Array[Byte], String] {
  let out : Array[Byte] = []
  let mut have = 0
  while have < need {
    // 从缓冲消耗可用字节
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

    // 缓冲为空了，再拉一批网络数据进来
    let n = match read_once_into(cur, io, read_win) {
      Ok(n) => n
      Err(e) => return Err(e)
    }
    if n == 0 {
      return Err("unexpected EOF while reading request body")
    }
  }
  Ok(out)
}
