///|
/// HTTP 协议“粗略类型”
/// - Http1         : 普通 HTTP/1.1
/// - Http2Preface  : 收到标准 HTTP/2 client preface 开头
pub enum HttpProtoKind {
  Http1
  Http2Preface
}

///|
/// 内部工具：检查 hay 是否以 needle 为前缀
fn bytes_starts_with(hay : Array[Byte], needle : Array[Byte]) -> Bool {
  if needle.length() == 0 {
    return true
  }
  if hay.length() < needle.length() {
    return false
  }
  let mut i = 0
  while i < needle.length() {
    if hay[i] != needle[i] {
      return false
    }
    i += 1
  }
  true
}


/// 规则：
/// 若前缀匹配完整的 HTTP/2 preface，则返回 Http2Preface
/// 否则一律按 Http1 处理
pub fn detect_http_proto_bytes(buf : Array[Byte]) -> HttpProtoKind {
  let preface_str = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
  let preface_bytes = @buf.string_to_utf8_bytes(preface_str).to_array()
  if bytes_starts_with(buf, preface_bytes) {
    HttpProtoKind::Http2Preface
  } else {
    HttpProtoKind::Http1
  }
}


///|
/// 在 Transport 上嗅探 HTTP 协议：
/// 尝试最多若干轮读取，最多读取 peek_limit 字节
/// 若前缀是 HTTP/2 preface，则返回 Http2Preface；否则视为 Http1
/// 嗅探过程中读到的字节最终会通过 push_rx 再放回 Transport，
/// 保证后续 HTTP/1 / HTTP/2 解码器可以“从头开始”继续读。
pub fn sniff_http_proto(
  io : @tsp.Transport,
  read_win? : Int = 64,
  max_rounds? : Int = 4,
) -> Result[HttpProtoKind, String] {
  let preface_str = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
  let preface_bytes = @buf.string_to_utf8_bytes(preface_str).to_array()
  let need_preface_len = preface_bytes.length()

  // 累积嗅探到的字节
  let peeked : Array[Byte] = []
  let mut rounds = 0
  while rounds < max_rounds && peeked.length() < need_preface_len {
    rounds += 1
    let buf : Array[Byte] = []
    buf.resize(read_win, 0)
    let n = match io.read(buf) {
      Ok(n) => n
      Err(@tsp.IoError::WouldBlock) =>
        // 暂时没有数据可读，结束嗅探
        break
      Err(@tsp.IoError::Eof) => break
      Err(@tsp.IoError::Closed) =>
        return Err("closed while sniffing http proto")
    }
    if n <= 0 {
      break
    }
    let chunk = @cor.copy_first(buf, n)
    // 累积到 peeked
    let mut i = 0
    while i < chunk.length() {
      peeked.push(chunk[i])
      i += 1
    }
  }

  // 把嗅探读出的所有字节“还给” Transport
  // PS：我们假设在嗅探开始之前 rx 中没有数据；需调用方遵守“连接刚建立就 sniff，一切解析之前”的约定
  if peeked.length() > 0 {
    io.push_rx(peeked)
  }

  // 根据 peeked 的内容来判断协议类型
  let kind = detect_http_proto_bytes(peeked)
  Ok(kind)
}

///|
/// 自动协议路由入口：
/// 目前仅支持 HTTP/1：
pub fn serve_connection_auto(
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
  let kind = match sniff_http_proto(io) {
    Ok(k) => k
    Err(e) => return Err(e)
  }
  match kind {
    HttpProtoKind::Http1 =>
      //  HTTP/1.1：直接走现有的 serve_loop
      @htp1.serve_loop(io, handler, max_headers, max_line, read_win, max_body~)
    HttpProtoKind::Http2Preface => {
      //  HTTP/2 preface：当前尚未支持，先回 505 + Connection: close
      let resp = "HTTP/1.1 505 HTTP Version Not Supported\r\n" +
        "Content-Length: 0\r\n" +
        "Connection: close\r\n" +
        "\r\n"
      ignore(@cor.write_ascii(io, resp))
      // 尝试关闭连接（忽略错误）
      ignore(io.close())
      Ok(())
    }
  }
}


///|
test "proto-detect: http2 preface bytes" {
  let preface_str = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
  let bs = @buf.string_to_utf8_bytes(preface_str).to_array()
  let kind = detect_http_proto_bytes(bs)
  match kind {
    HttpProtoKind::Http2Preface => ()
    _ => assert_eq(true, false)
  }
}

///|
test "proto-detect: http1 request line bytes" {
  let req_str = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
  let bs = @buf.string_to_utf8_bytes(req_str).to_array()
  let kind = detect_http_proto_bytes(bs)
  match kind {
    HttpProtoKind::Http1 => ()
    _ => assert_eq(true, false)
  }
}


///|
test "proto-sniff: http2 preface via transport" {
  let preface_str = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
  let bs = @buf.string_to_utf8_bytes(preface_str).to_array()
  let empty : Array[Byte] = []
  let io = try @tsp.from_inmemory(empty) catch {
    _ => {
      assert_eq(true, false)
      return
    }
  } noraise {
    t => t
  }

  // 把 HTTP/2 preface 推入 rx
  io.push_rx(bs)

  // 嗅探协议类型
  let kind = match sniff_http_proto(io) {
    Ok(k) => k
    Err(_e) => {
      assert_eq(true, false)
      return
    }
  }
  match kind {
    HttpProtoKind::Http2Preface => ()
    _ => assert_eq(true, false)
  }
}

///|
test "proto-sniff: http1 request via transport" {
  let req_str = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
  let bs = @buf.string_to_utf8_bytes(req_str).to_array()
  let empty : Array[Byte] = []
  let io = try @tsp.from_inmemory(empty) catch {
    _ => {
      assert_eq(true, false)
      return
    }
  } noraise {
    t => t
  }
  io.push_rx(bs)
  let kind = match sniff_http_proto(io) {
    Ok(k) => k
    Err(_e) => {
      assert_eq(true, false)
      return
    }
  }
  match kind {
    HttpProtoKind::Http1 => ()
    _ => assert_eq(true, false)
  }
}


///|
test "proto-router: http1 request routed to http1 serve_loop" {
  // 构造一个简单 GET 请求
  let req_str = "GET / HTTP/1.1\r\n" +
    "Host: example.com\r\n" +
    "Connection: close\r\n" +
    "\r\n"
  let bs = @buf.string_to_utf8_bytes(req_str).to_array()

  // in-memory transport：空 init + push_rx
  let empty : Array[Byte] = []
  let io = try @tsp.from_inmemory(empty) catch {
    _ => {
      assert_eq(true, false)
      return
    }
  } noraise {
    t => t
  }
  io.push_rx(bs)

  // 使用自动路由入口，handler 用 http1 里的 hello_handler
  let r = serve_connection_auto(
    io,
    @htp1.hello_handler,
    64, // max_headers
    4096, // max_line
    4096, // read_win
    max_body=1 * 1024 * 1024,
  )
  match r {
    Ok(_) => ()
    Err(e) => {
      // 不期望这里失败
      assert_eq(e.length() >= 0, false)
      return
    }
  }

  // 取出响应并做基本断言
  let tx = io.take_tx()
  let s = (try? @buf.utf8_bytes_to_string(Bytes::from_array(tx))).unwrap_or("")

  // 应为 200 OK，且 body 包含 "Hello, MoonBit!"
  assert_eq(@cor.str_contains(s, "HTTP/1.1 200 OK"), true)
  assert_eq(@cor.str_contains(s, "Hello, MoonBit!"), true)
}


///|
test "proto-router: http2 preface gets 505 response" {
  let preface_str = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
  let bs = @buf.string_to_utf8_bytes(preface_str).to_array()
  let empty : Array[Byte] = []
  let io = try @tsp.from_inmemory(empty) catch {
    _ => {
      assert_eq(true, false)
      return
    }
  } noraise {
    t => t
  }
  io.push_rx(bs)

  // handler 此时理论上不会被调用，我们给一个“占位”的 handler
  let dummy_handler = fn(
    _req : @cor.Request,
  ) -> (@cor.StatusCode, Map[String, String], Array[Byte], Bool) {
    let hs : Map[String, String] = Map::new()
    let body : Array[Byte] = []
    (@cor.StatusCode::InternalServerError, hs, body, false)
  }
  let r = serve_connection_auto(
    io,
    dummy_handler,
    64,
    4096,
    4096,
    max_body=1 * 1024 * 1024,
  )
  match r {
    Ok(_) => ()
    Err(e) => {
      assert_eq(e.length() >= 0, false)
      return
    }
  }
  let tx = io.take_tx()
  let s = (try? @buf.utf8_bytes_to_string(Bytes::from_array(tx))).unwrap_or("")

  // 期望直接回 505，并带有 Connection: close
  assert_eq(@cor.str_starts_with(s, "HTTP/1.1 505 HTTP Version Not Supported"), true)
  assert_eq(@cor.str_contains(s, "Connection: close"), true)
}
