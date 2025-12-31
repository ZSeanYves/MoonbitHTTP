///|
/// HTTP 协议“粗略类型”
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


// 一个最简单的处理器：无论请求什么都返回 200 text/plain: "Hello"
///|
fn hello_handler(
  req : @cor.Request,
) -> (@cor.StatusCode, Map[String, String], Array[Byte], Bool) {
  ignore(req) // 先不看请求
  let hs : Map[String, String] = Map::new()
  hs.set("Content-Type", "text/plain")
  let body = @buf.string_to_utf8_bytes("Hello, MoonBit!").to_array()
  (@cor.StatusCode::OK, hs, body, false) // 非 chunked，自动 Content-Length
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
/// - HTTP/1：调用 http1::serve_loop
/// - HTTP/2：调用 http2::serve_once（单请求 demo 版）
///
/// 返回统一的 Herror，便于上层区分 Io / Proto / User 三类错误。
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
) -> Result[Unit, @cor.Herror] {
  let kind = match sniff_http_proto(io) {
    Ok(k) => k
    Err(e) => return Err(@cor.err_proto("sniff_http_proto failed: " + e))
  }

  match kind {
    HttpProtoKind::Http1 =>
      // HTTP/1.1：直接走现有的 serve_loop
      @htp1.serve_loop(io, handler, max_headers, max_line, read_win, max_body~)

    HttpProtoKind::Http2Preface =>
      // HTTP/2：使用 http2 的单请求 runtime
      @htp2.serve_once(io, handler, read_win)
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
    hello_handler,
    64, // max_headers
    4096, // max_line
    4096, // read_win
    max_body=1 * 1024 * 1024,
  )
  match r {
    Ok(_) => ()
    Err(e) => {
      // 不期望这里失败
      assert_eq(@cor.error_to_string(e).length() >= 0, false)
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
///|
test "proto-router: http2 basic GET routed to h2 runtime" {
  // 1. 构造“客户端 → 服务器”的字节流：
  //    preface + SETTINGS（不带 ACK；不必发送 HEADERS）
  let preface_bytes = @buf.string_to_utf8_bytes(@htp2.H2_CLIENT_PREFACE).to_array()
  let client_settings : Array[@htp2.H2SettingKV] = []
  let sf = @htp2.build_settings_frame(client_settings, false)
  let rx : Array[Byte] = []
  // 追加 preface
  let mut i = 0
  while i < preface_bytes.length() {
    rx.push(preface_bytes[i])
    i += 1
  }
  // 追加 SETTINGS 帧
  i = 0
  while i < sf.length() {
    rx.push(sf[i])
    i += 1
  }

  // 2. in-memory transport：空 init + push_rx
  let empty : Array[Byte] = []
  let io = try @tsp.from_inmemory(empty) catch {
    _ => {
      assert_eq(true, false)
      return
    }
  } noraise {
    t => t
  }
  io.push_rx(rx)

  // 3. handler：如果 HTTP/2 runtime 真能构造出 Request，就返回 200 + "Hello H2"
  let handler = fn(
    _req : @cor.Request,
  ) -> (@cor.StatusCode, Map[String, String], Array[Byte], Bool) {
    let hs : Map[String, String] = Map::new()
    let body = @buf.string_to_utf8_bytes("Hello H2").to_array()
    (@cor.StatusCode::OK, hs, body, false)
  }

  // 4. 走自动路由入口（我们这里不对 Result 做强断言，只做黑盒检查）
  let _ = serve_connection_auto(
    io,
    handler,
    64, // max_headers（只对 HTTP/1 有意义）
    4096, // max_line    （只对 HTTP/1 有意义）
    4096, // read_win
    max_body=1 * 1024 * 1024,
  )

  // 5. 检查 server 写出的第一个 HTTP/2 帧是否是 SETTINGS ack
  let tx = io.take_tx()
  // 必须有输出
  assert_eq(tx.length() > 0, true)

  // 用 http2 模块自带的 read_frame 再解一遍
  let io2 = try @tsp.from_inmemory(tx) catch {
    _ => {
      assert_eq(true, false)
      return
    }
  } noraise {
    t => t
  }
  let cur2 = @tsp.buf_new()
  let f0 = match
    @htp2.read_frame(
      cur2,
      io2,
      4096,
      max_frame_size=@htp2.H2_DEFAULT_MAX_FRAME_SIZE,
    ) {
    Ok(x) => x
    Err(e) => {
      // 如果这里失败，说明根本没有写出合法的 HTTP/2 帧
      println("proto-router h2: read_frame failed: " + e)
      assert_eq(true, false)
      return
    }
  }

  // 期望第一帧是 SETTINGS，且带 ACK 标志
  assert_eq(f0.header.typ == @htp2.H2_FRAME_SETTINGS, true)
  assert_eq((f0.header.flags & @htp2.H2_FLAGS_ACK) != 0, true)
}
