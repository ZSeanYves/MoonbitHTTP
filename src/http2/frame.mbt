// 局部实现，避免依赖 http1
// 对 encoder 和 read 的补丁：
///|
fn read_missing_into(
  cur : @tsp.BufCursor,
  io : @tsp.Transport,
  missing : Int, // 期望最多读取的字节数
) -> Result[Int, String] {
  if missing <= 0 {
    return Ok(0)
  }
  let buf : Array[Byte] = []
  buf.resize(missing, 0)
  match io.read(buf) {
    Ok(n) => {
      if n > 0 {
        let chunk : Array[Byte] = []
        let mut i = 0
        while i < n {
          chunk.push(buf[i])
          i += 1
        }
        cur.buf_push(chunk)
      }
      Ok(n)
    }
    // in-memory 或非阻塞：统一视作 0
    Err(@tsp.IoError::WouldBlock) => Ok(0)
    Err(@tsp.IoError::Eof) => Ok(0)
    Err(@tsp.IoError::Closed) => Ok(0)
  }
}

// 编解码：帧头

///|
fn encode_frame_header(h : H2FrameHeader) -> Array[Byte] {
  let out : Array[Byte] = []
  // length: 24-bit big-endian
  let len = h.length
  out.push(((len >> 16) & 0xFF).to_byte())
  out.push(((len >> 8) & 0xFF).to_byte())
  out.push((len & 0xFF).to_byte())

  // type: 8-bit
  out.push((h.typ & 0xFF).to_byte())

  // flags: 8-bit
  out.push((h.flags & 0xFF).to_byte())

  // stream identifier: 1-bit R (0) + 31-bit ID, big-endian
  let sid = h.stream_id & 0x7FFFFFFF
  out.push(((sid >> 24) & 0x7F).to_byte()) // 最高位必须为 0
  out.push(((sid >> 16) & 0xFF).to_byte())
  out.push(((sid >> 8) & 0xFF).to_byte())
  out.push((sid & 0xFF).to_byte())
  out
}

// 读帧头（先预取 9 字节，再消费）

///|
fn decode_frame_header(
  cur : @tsp.BufCursor,
  io : @tsp.Transport,
  _read_win : Int,
  max_frame_size : Int,
) -> Result[H2FrameHeader, String] {
  let mut rounds = 0
  while cur.buf_len() < 9 {
    let need = 9 - cur.buf_len()
    let _ = match read_missing_into(cur, io, need) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    rounds += 1
    if rounds > 4096 {
      return Err("h2: header not available")
    }
  }
  let bs = cur.buf_take(9)
  ignore(cur.buf_drain(9))

  // &0xFF 做无符号处理
  let b0 = bs[0].to_int() & 0xFF
  let b1 = bs[1].to_int() & 0xFF
  let b2 = bs[2].to_int() & 0xFF
  let b3 = bs[3].to_int() & 0xFF
  let b4 = bs[4].to_int() & 0xFF
  let b5 = bs[5].to_int() & 0xFF
  let b6 = bs[6].to_int() & 0xFF
  let b7 = bs[7].to_int() & 0xFF
  let b8 = bs[8].to_int() & 0xFF
  let len = (b0 << 16) | (b1 << 8) | b2
  let typ = b3
  let flags = b4
  if (b5 & 0x80) != 0 {
    return Err("h2 frame: stream-id has reserved bit set")
  }
  let sid = ((b5 & 0x7F) << 24) | (b6 << 16) | (b7 << 8) | b8
  if len < 0 || len > 0xFFFFFF {
    return Err("h2 frame: invalid length")
  }
  if len > max_frame_size {
    return Err("h2 frame: length exceeds max_frame_size")
  }
  ////println(
  //  "H2 header parsed: len=" +
  //  len.to_string() +
  //  " typ=" +
  //  typ.to_string() +
  //  " flags=" +
  //  flags.to_string() +
  //  " sid=" +
  //  sid.to_string() +
  //  " remaining=" +
  //  cur.buf_len().to_string(),
  //)
  Ok({ length: len, typ, flags, stream_id: sid })
}

// 读完整帧（头 + 载荷），按帧长再动态预取  

///|
pub fn read_frame(
  cur : @tsp.BufCursor,
  io : @tsp.Transport,
  read_win : Int, // 保留签名（未使用）
  max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE,
) -> Result[H2Frame, String] {
  let h = match decode_frame_header(cur, io, read_win, max_frame_size) {
    Ok(x) => x
    Err(e) => return Err(e)
  }
  let need = h.length
  ////println(
  //  "H2 payload want=" +
  //  need.to_string() +
  //  " cur_have=" +
  //  cur.buf_len().to_string(),
  //)
  if need > 0 {
    let mut rounds = 0
    while cur.buf_len() < need {
      let missing = need - cur.buf_len()
      let _ = match read_missing_into(cur, io, missing) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      rounds += 1
      if rounds > 4096 {
        return Err("h2: payload not available")
      }
    }
  }
  let payload = if need == 0 {
    []
  } else {
    let bs = cur.buf_take(need)
    ignore(cur.buf_drain(need))
    bs
  }
  Ok({ header: h, payload })
}

// 连接前言（客户端发送 / 服务器校验）
///|
fn client_preface_bytes() -> Array[Byte] {
  @buf.string_to_utf8_bytes(H2_CLIENT_PREFACE).to_array()
}

// 服务器侧校验：严格读取并仅消费 24 字节前言，剩余字节留在 cur 里

///|
fn read_and_check_client_preface(
  cur : @tsp.BufCursor,
  io : @tsp.Transport,
  _read_win : Int, // 不再用固定窗口
) -> Result[Unit, String] {
  let need = 24

  // 按“缺多少”增量读取，避免把后续帧一口吞掉
  let mut rounds = 0
  while cur.buf_len() < need {
    let missing = need - cur.buf_len()
    let buf : Array[Byte] = []
    buf.resize(missing, 0)
    let n = match io.read(buf) {
      Ok(n) => n
      Err(@tsp.IoError::WouldBlock) => 0
      Err(@tsp.IoError::Eof) => 0
      Err(@tsp.IoError::Closed) => 0
    }
    if n > 0 {
      let chunk : Array[Byte] = []
      let mut i = 0
      while i < n {
        chunk.push(buf[i])
        i += 1
      }
      cur.buf_push(chunk)
    }
    rounds += 1
    if rounds > 4096 {
      return Err("h2 preface: not available")
    }
  }

  // 只消费 24B 作为前言，后续（如 SETTINGS 帧头 9B）留在 cur 里
  let bs = cur.buf_take(need)
  ignore(cur.buf_drain(need))
  let s = (try? @buf.utf8_bytes_to_string(Bytes::from_array(bs))).unwrap_or("")
  if s != H2_CLIENT_PREFACE {
    return Err("h2 preface mismatch")
  }
  ////println("after preface, cur_have=" + cur.buf_len().to_string())
  Ok(())
}

// 编码 SETTINGS 的 payload（不含帧头）

///|
fn encode_settings_payload(kvs : Array[H2SettingKV]) -> Array[Byte] {
  let out : Array[Byte] = []
  for kv in kvs {
    let id = kv.id & 0xFFFF
    let v = kv.value
    out.push(((id >> 8) & 0xFF).to_byte())
    out.push((id & 0xFF).to_byte())
    out.push(((v >> 24) & 0xFF).to_byte())
    out.push(((v >> 16) & 0xFF).to_byte())
    out.push(((v >> 8) & 0xFF).to_byte())
    out.push((v & 0xFF).to_byte())
  }
  out
}

// 解析 SETTINGS 的 payload

///|
fn decode_settings_payload(
  bs : Array[Byte],
) -> Result[Array[H2SettingKV], String] {
  if bs.length() % 6 != 0 {
    return Err("h2 settings: invalid payload length")
  }
  let out : Array[H2SettingKV] = []
  let mut i = 0
  while i < bs.length() {
    let id = (bs[i].to_int() << 8) | bs[i + 1].to_int()
    let v = (bs[i + 2].to_int() << 24) |
      (bs[i + 3].to_int() << 16) |
      (bs[i + 4].to_int() << 8) |
      bs[i + 5].to_int()
    out.push({ id, value: v })
    i += 6
  }
  Ok(out)
}

// 生成一个完整 SETTINGS 帧（stream=0；可带 ACK 标志，payload 为空）

///|
pub fn build_settings_frame(
  kvs : Array[H2SettingKV],
  ack : Bool,
) -> Array[Byte] {
  let payload = if ack { [] } else { encode_settings_payload(kvs) }
  let flags = if ack { H2_FLAGS_ACK } else { 0 }
  let h : H2FrameHeader = {
    length: payload.length(),
    typ: H2_FRAME_SETTINGS,
    flags,
    stream_id: 0,
  }
  let out = encode_frame_header(h)
  for b in payload {
    out.push(b)
  }
  out
}

// PING 帧（payload 8 字节）

///|
fn build_ping_frame(opaque8 : Array[Byte], ack : Bool) -> Array[Byte] {
  // 需要 8 字节，不够补 0，多了截断
  let p : Array[Byte] = []
  let need = 8
  let mut i = 0
  while i < need {
    p.push(if i < opaque8.length() { opaque8[i] } else { 0 })
    i += 1
  }
  let flags = if ack { H2_FLAGS_ACK } else { 0 }
  let h : H2FrameHeader = { length: 8, typ: H2_FRAME_PING, flags, stream_id: 0 }
  let out = encode_frame_header(h)
  for b in p {
    out.push(b)
  }
  out
}

// GOAWAY（最小版）：last-stream-id(32) + error-code(32) + optional debug data

///|
fn _build_goaway_frame(
  last_stream_id : Int,
  error_code : Int,
  debug : Array[Byte],
) -> Array[Byte] {
  // last_stream_id: R bit = 0
  let sid = last_stream_id & 0x7FFFFFFF
  let payload : Array[Byte] = []
  payload.push(((sid >> 24) & 0x7F).to_byte()) // 最高位保留 0
  payload.push(((sid >> 16) & 0xFF).to_byte())
  payload.push(((sid >> 8) & 0xFF).to_byte())
  payload.push((sid & 0xFF).to_byte())
  payload.push(((error_code >> 24) & 0xFF).to_byte())
  payload.push(((error_code >> 16) & 0xFF).to_byte())
  payload.push(((error_code >> 8) & 0xFF).to_byte())
  payload.push((error_code & 0xFF).to_byte())
  for b in debug {
    payload.push(b)
  }
  let h : H2FrameHeader = {
    length: payload.length(),
    typ: H2_FRAME_GOAWAY,
    flags: 0,
    stream_id: 0,
  }
  let out = encode_frame_header(h)
  for b in payload {
    out.push(b)
  }
  out
}

// 解析一帧是否 SETTINGS，返回 (ack, kvs)
// - ack=true 时 payload 必须为空

///|
fn parse_settings_frame(
  f : H2Frame,
) -> Result[(Bool, Array[H2SettingKV]), String] {
  if f.header.typ != H2_FRAME_SETTINGS {
    return Err("not a SETTINGS frame")
  }
  let ack = (f.header.flags & H2_FLAGS_ACK) != 0
  if ack {
    if f.payload.length() != 0 {
      return Err("SETTINGS ack must have empty payload")
    }
    return Ok((true, []))
  } else {
    match decode_settings_payload(f.payload) {
      Ok(kvs) => Ok((false, kvs))
      Err(e) => Err(e)
    }
  }
}

// 解析一帧是否 PING，返回 (ack, opaque8)

///|
fn parse_ping_frame(f : H2Frame) -> Result[(Bool, Array[Byte]), String] {
  if f.header.typ != H2_FRAME_PING {
    return Err("not a PING frame")
  }
  if f.payload.length() != 8 {
    return Err("PING payload must be 8 bytes")
  }
  let ack = (f.header.flags & H2_FLAGS_ACK) != 0
  Ok((ack, f.payload))
}

// —— WINDOW_UPDATE ——

///|
fn _build_window_update_frame(
  stream_id : Int,
  increment : Int,
) -> Array[Byte] {
  // 这里仅按 31-bit 写
  let inc = increment & 0x7FFFFFFF
  let p : Array[Byte] = []
  p.push(((inc >> 24) & 0x7F).to_byte()) // 最高位保留为 0
  p.push(((inc >> 16) & 0xFF).to_byte())
  p.push(((inc >> 8) & 0xFF).to_byte())
  p.push((inc & 0xFF).to_byte())
  let h : H2FrameHeader = {
    length: 4,
    typ: H2_FRAME_WINDOW_UPDATE,
    flags: 0,
    stream_id: stream_id & 0x7FFFFFFF,
  }
  let out = encode_frame_header(h)
  for b in p {
    out.push(b)
  }
  out
}

///|
fn _parse_window_update_increment(f : H2Frame) -> Result[Int, String] {
  if f.header.typ != H2_FRAME_WINDOW_UPDATE {
    return Err("not a WINDOW_UPDATE frame")
  }
  if f.payload.length() != 4 {
    return Err("WINDOW_UPDATE payload must be 4 bytes")
  }
  let b0 = f.payload[0].to_int() & 0xFF
  let b1 = f.payload[1].to_int() & 0xFF
  let b2 = f.payload[2].to_int() & 0xFF
  let b3 = f.payload[3].to_int() & 0xFF
  let inc = ((b0 & 0x7F) << 24) | (b1 << 16) | (b2 << 8) | b3
  if inc == 0 {
    return Err("WINDOW_UPDATE increment must be > 0")
  }
  Ok(inc)
}

// —— RST_STREAM ——

///|
fn _build_rst_stream_frame(stream_id : Int, error_code : Int) -> Array[Byte] {
  let ec = error_code & 0xFFFFFFFF
  let p : Array[Byte] = []
  p.push(((ec >> 24) & 0xFF).to_byte())
  p.push(((ec >> 16) & 0xFF).to_byte())
  p.push(((ec >> 8) & 0xFF).to_byte())
  p.push((ec & 0xFF).to_byte())
  let h : H2FrameHeader = {
    length: 4,
    typ: H2_FRAME_RST_STREAM,
    flags: 0,
    stream_id: stream_id & 0x7FFFFFFF,
  }
  let out = encode_frame_header(h)
  for b in p {
    out.push(b)
  }
  out
}

///|
fn _parse_rst_stream_error(f : H2Frame) -> Result[Int, String] {
  if f.header.typ != H2_FRAME_RST_STREAM {
    return Err("not a RST_STREAM frame")
  }
  if f.payload.length() != 4 {
    return Err("RST_STREAM payload must be 4 bytes")
  }
  let b0 = f.payload[0].to_int() & 0xFF
  let b1 = f.payload[1].to_int() & 0xFF
  let b2 = f.payload[2].to_int() & 0xFF
  let b3 = f.payload[3].to_int() & 0xFF
  let ec = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
  Ok(ec)
}

///|
fn h2_client_start(
  io : @tsp.Transport,
  settings : Array[H2SettingKV],
) -> Result[Unit, String] {
  // 发送前言
  let pre = client_preface_bytes()
  try io.write_all(pre) catch {
    _ => return Err("write client preface failed")
  } noraise {
    _ => ()
  }
  // 发送 SETTINGS
  let sf = build_settings_frame(settings, false)
  try io.write_all(sf) catch {
    _ => Err("write client settings failed")
  } noraise {
    _ => Ok(())
  }
}

///|
fn h2_server_accept_and_ack(
  cur : @tsp.BufCursor,
  io : @tsp.Transport,
  read_win : Int,
  max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE,
) -> Result[Array[H2SettingKV], String] {
  match read_and_check_client_preface(cur, io, read_win) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let f = match read_frame(cur, io, read_win, max_frame_size~) {
    Ok(x) => x
    Err(e) => return Err(e)
  }
  let (ack, kvs) = match parse_settings_frame(f) {
    Ok(t) => t
    Err(e) => return Err(e)
  }
  if ack {
    // 客户端首帧不应是 ACK
    return Err("unexpected SETTINGS ack from client")
  }
  // 回 ACK
  let ack_bytes = build_settings_frame([], true)
  try io.write_all(ack_bytes) catch {
    _ => return Err("write settings ack failed")
  } noraise {
    _ => ()
  }
  Ok(kvs)
}


/// 把 HTTP/2 的伪头 + 正常头数组，转换成 @cor.Request
/// 目前只做最小实现：只识别 GET/POST，其它方法暂时当作 GET
fn h2_headers_to_request(
  _info : H2HeadersInfo,
  hs : Array[HpackHeader],
) -> Result[@cor.Request, String] {
  let mut method_str = ""
  let mut path = ""
  let mut _scheme = ""
  let mut _authority = ""
  let headers : Map[String, String] = Map::new()
  let mut i = 0
  while i < hs.length() {
    let h = hs[i]
    if h.name.length() > 0 && h.name[0] == ':' {
      if h.name == ":method" {
        method_str = h.value
      } else if h.name == ":path" {
        path = h.value
      } else if h.name == ":scheme" {
        _scheme = h.value
      } else if h.name == ":authority" {
        _authority = h.value
      }
    } else {
      headers.set(h.name, h.value)
    }
    i += 1
  }
  if path.length() == 0 {
    path = "/"
  }
  let _method = if method_str == "POST" {
    @cor.Method::POST
  } else if method_str == "HEAD" {
    @cor.Method::HEAD
  } else if method_str == "PUT" {
    @cor.Method::PUT
  } else if method_str == "DELETE" {
    @cor.Method::DELETE
  } else {
    @cor.Method::GET
  }
  let line : @cor.RequestLine = {
    http_method: _method,
    target: path,
    version: "HTTP/2",
  }
  Ok({ line, headers, body: @cor.Body::Empty }, // 目前不解析请求体 DATA，后面再扩展
  )
}




/// HTTP/2：单请求版本的流式 server。
pub fn serve_once_body_streaming(
  cur : @tsp.BufCursor,
  io : @tsp.Transport,
  handler : (@cor.Request) -> (
    @cor.StatusCode,
    Map[String, String],
    @cor.Body,
    Bool,
  ),
  read_win : Int,
  max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE,
) -> Result[Unit, @cor.Herror] {
  // 1）握手：接受 preface + SETTINGS，并回 ACK
  match h2_server_accept_and_ack(cur, io, read_win, max_frame_size~) {
    Ok(_) => ()
    Err(e) =>
      return Err(@cor.err_proto("h2 serve_once: handshake failed: " + e))
  }

  // 2）读取首个 HEADERS 帧，组装成 header 列表
  let (info, hs) = match
    read_headers_as_list(cur, io, read_win, max_frame_size~) {
    Ok(t) => t
    Err(e) =>
      return Err(@cor.err_proto("h2 serve_once: read headers failed: " + e))
  }

  // 目前 demo 只支持 stream_id = 1
  if info.stream_id != 1 {
    return Err(
      @cor.err_proto("h2 serve_once: only stream 1 supported in demo"),
    )
  }

  // 3）从伪头和普通头构造 Request
  let req = match h2_headers_to_request(info, hs) {
    Ok(r) => r
    Err(e) =>
      return Err(@cor.err_proto("h2 serve_once: build request failed: " + e))
  }

  // 4）调用用户 handler
  let (status_code, user_headers, body, _ignored_flag) = handler(req)

  // 5）构造响应 HEADERS
  let status_int = @cor.status_code_value(status_code)
  let resp_hs : Array[HpackHeader] = {
    let a : Array[HpackHeader] = []
    a.push({ name: ":status", value: status_int.to_string() })
    for k in user_headers.keys() {
      let v = user_headers.get(k).unwrap_or("")
      a.push({ name: k, value: v })
    }
    a
  }
  let body_is_empty = match body {
    @cor.Body::Empty => true
    _ => false
  }
  let hdr_bytes = build_headers_frames_from_list(
    1, // 目前只支持单流
    resp_hs,
    body_is_empty,
    max_frame_size~,
  )
  try io.write_all(hdr_bytes) catch {
    _ =>
      return Err(
        @cor.err_io("h2 serve_once: write response headers failed"),
      )
  } noraise {
    _ => ()
  }
  if body_is_empty {
    return Ok(())
  }

  // 6）根据 Body 类型发送 DATA（支持 Bytes / Stream）
  match body {
    @cor.Body::Bytes(bs) => {
      let data_bytes = build_data_frames(1, bs, true, max_frame_size~)
      try io.write_all(data_bytes) catch {
        _ => return Err(
          @cor.err_io("h2 serve_once: write response body failed"),
        )
      } noraise {
        _ => ()
      }
      Ok(())
    }
    @cor.Body::Stream(next) => {
      let mut rounds = 0
      while true {
        rounds += 1
        if rounds > 4096 {
          return Err(
            @cor.err_proto("h2 serve_once: too many body stream rounds"),
          )
        }
        let (chunk, done) = match next() {
          Ok(p) => p
          Err(e) =>
            return Err(
              @cor.err_user(
                "h2 serve_once: body stream error: " + e,
              ),
            )
        }
        if chunk.length() == 0 && !done {
          // 空块但未结束，就继续拉下一轮
          continue
        }
        let data_bytes = build_data_frames(1, chunk, done, max_frame_size~)
        try io.write_all(data_bytes) catch {
          _ => return Err(
            @cor.err_io("h2 serve_once: write response data failed"),
          )
        } noraise {
          _ => ()
        }
        if done {
          break
        }
      }
      Ok(())
    }
    _ => Ok(())
  }
}

///|
/// HTTP/2：对外的单请求 server runtime，handler 形状与 http1::serve_loop 一致：
///   Request -> (StatusCode, headers, body_bytes, _is_chunked)
/// 注意：HTTP/2 不使用 chunked，这里的 Bool 会被忽略。
pub fn serve_once(
  io : @tsp.Transport,
  handler : (@cor.Request) -> (
    @cor.StatusCode,
    Map[String, String],
    Array[Byte],
    Bool,
  ),
  read_win : Int,
  max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE,
) -> Result[Unit, @cor.Herror] {
  let cur = @tsp.buf_new()

  // 把 bytes-handler 适配成 Body-handler，复用 serve_once_body_streaming
  let body_handler = fn(
    req : @cor.Request,
  ) -> (@cor.StatusCode, Map[String, String], @cor.Body, Bool) {
    let (status, hdrs, body_bytes, _ignored_chunked) = handler(req)
    // HTTP/2 没有 chunked 编码，这里统一用 Bytes
    (status, hdrs, @cor.Body::Bytes(body_bytes), false)
  }

  match
    serve_once_body_streaming(cur, io, body_handler, read_win, max_frame_size~) {
    Ok(_) => Ok(())
    Err(e) => Err(e)
  }
}




// 服务器一次完整处理：preface+SETTINGS(ack) → 读取请求 HEADERS → 回 200 和 DATA("hello")
///|
pub fn h2_server_handle_get_hello(
  cur : @tsp.BufCursor,
  io : @tsp.Transport,
  read_win : Int,
  max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE,
) -> Result[Unit, String] {
  // 客户端前言 + SETTINGS → 发送 ACK
  let _ = match h2_server_accept_and_ack(cur, io, read_win) {
    Ok(kvs) => kvs
    Err(e) => return Err(e)
  }

  // 读取请求 HEADERS（要求单流：stream 1；GET 可设置 END_STREAM）
  let (info, _) = match
    read_headers_as_list(cur, io, read_win, max_frame_size~) {
    Ok(t) => t
    Err(e) => return Err(e)
  }
  if info.stream_id != 1 {
    return Err("only stream 1 supported in demo")
  }

  // 构造响应 HEADERS（:status 200, content-length 5, content-type text/plain）
  let resp_hs : Array[HpackHeader] = {
    let a : Array[HpackHeader] = []
    a.push({ name: ":status", value: "200" })
    a.push({ name: "content-type", value: "text/plain" })
    a.push({ name: "content-length", value: "5" })
    a
  }
  let hdr_bytes = build_headers_frames_from_list(
    1,
    resp_hs,
    false,
    max_frame_size~,
  )

  // 构造 DATA("hello")，END_STREAM=1
  let body = @buf.string_to_utf8_bytes("hello").to_array()
  let data_bytes = build_data_frames(1, body, true, max_frame_size~)

  // 写出
  try io.write_all(hdr_bytes) catch {
    _ => return Err("write response headers failed")
  } noraise {
    _ => ()
  }
  try io.write_all(data_bytes) catch {
    _ => return Err("write response data failed")
  } noraise {
    _ => ()
  }
  Ok(())
}


///|
test "h2: server_handle_get_hello end-to-end" {

  // 1.1 HTTP/2 preface
  let pre = client_preface_bytes()

  // 1.2 客户端 SETTINGS（这里就空 payload）
  let client_settings : Array[H2SettingKV] = []
  let sf = build_settings_frame(client_settings, false)

  // 1.3 构造请求 HEADERS（:method / :path / :scheme / :authority）
  let req_hs : Array[HpackHeader] = {
    let a : Array[HpackHeader] = []
    a.push({ name: ":method", value: "GET" })
    a.push({ name: ":path", value: "/" })
    a.push({ name: ":scheme", value: "https" })
    a.push({ name: ":authority", value: "example.com" })
    a
  }
  // HEADERS 帧，stream 1，END_STREAM = true
  let req_hdr_bytes = build_headers_frames_from_list(
    1,
    req_hs,
    true,
    max_frame_size=H2_DEFAULT_MAX_FRAME_SIZE,
  )

  // 1.4 拼成完整“客户端入站数据流”
  let rx : Array[Byte] = []
  // preface
  for b in pre {
    rx.push(b)
  }
  // SETTINGS
  for b in sf {
    rx.push(b)
  }
  // HEADERS(GET /)
  for b in req_hdr_bytes {
    rx.push(b)
  }

  // 建立 in-memory transport，喂入 rx，然后跑 h2_server_handle_get_hello 

  let empty : Array[Byte] = []
  let io = try @tsp.from_inmemory(empty) catch {
    _ => {
      let a = true
      assert_eq(a, false)
      return
    }
  } noraise {
    t => t
  }
  io.push_rx(rx)
  let cur = @tsp.buf_new()
  let read_win = 4096
  match h2_server_handle_get_hello(cur, io, read_win) {
    Ok(_) => ()
    Err(e) => {
      // 不应该失败
      assert_eq(e.length() >= 0, false)
      return
    }
  }

  // 刷新写缓冲
  match io.flush() {
    Ok(_) => ()
    Err(_e) => () // 测试里忽略 flush 失败
  }

  // 取出服务端写出的响应字节：1 个 SETTINGS ack 帧，1 组 HEADERS(:status 200, content-type, content-length)，1 个 DATA("hello", END_STREAM)
  let tx = io.take_tx()

  // 3. 用一个新的 Transport/BufCursor，把响应字节按帧解析出来并断言 

  let io2 = try @tsp.from_inmemory(tx) catch {
    _ => {
      let a = true
      assert_eq(a, false)
      return
    }
  } noraise {
    t => t
  }
  let cur2 = @tsp.buf_new()

  // 3.1 读第一帧：应该是 SETTINGS ack（stream 0, flags & ACK != 0）
  let f0 = match
    read_frame(cur2, io2, read_win, max_frame_size=H2_DEFAULT_MAX_FRAME_SIZE) {
    Ok(x) => x
    Err(e) => {
      assert_eq(e.length() >= 0, false)
      return
    }
  }
  // 类型必须是 SETTINGS
  assert_eq(f0.header.typ == H2_FRAME_SETTINGS, true)
  // 解析 SETTINGS 帧，应该是 ack=true，payload 为空
  let (ack0, kvs0) = match parse_settings_frame(f0) {
    Ok(t) => t
    Err(e) => {
      assert_eq(e.length() >= 0, false)
      return
    }
  }
  assert_eq(ack0, true)
  assert_eq(kvs0.length(), 0)

  // 3.2 读 HEADERS(+CONTINUATION...)，解出 header 列表
  let (info, hs) = match
    read_headers_as_list(
      cur2,
      io2,
      read_win,
      max_frame_size=H2_DEFAULT_MAX_FRAME_SIZE,
    ) {
    Ok(t) => t
    Err(e) => {
      assert_eq(e.length() >= 0, false)
      return
    }
  }

  // 必须是同一个 stream（1）
  assert_eq(info.stream_id, 1)
  // GET 请求有 body 吗？这里服务器 demo 回复时 DATA 里带 END_STREAM，
  // 所以 HEADERS 这边 end_stream 应该是 false
  assert_eq(info.end_stream, false)

  // 3.3 在 hpacks 里查关键 header
  let mut status_val = ""
  let mut ctype_val = ""
  let mut clen_val = ""
  for h in hs {
    if h.name == ":status" {
      status_val = h.value
    } else if h.name == "content-type" {
      ctype_val = h.value
    } else if h.name == "content-length" {
      clen_val = h.value
    }
  }

  // 断言响应 status / headers
  assert_eq(status_val, "200")
  assert_eq(ctype_val, "text/plain")
  assert_eq(clen_val, "5")

  // 3.4 再读一帧：应该是 DATA("hello")，带 END_STREAM
  let f1 = match
    read_frame(cur2, io2, read_win, max_frame_size=H2_DEFAULT_MAX_FRAME_SIZE) {
    Ok(x) => x
    Err(e) => {
      assert_eq(e.length() >= 0, false)
      return
    }
  }
  assert_eq(f1.header.typ == H2_FRAME_DATA, true)
  assert_eq(f1.header.stream_id, 1)
  // DATA 应该带 END_STREAM
  assert_eq((f1.header.flags & H2_FLAGS_END_STREAM) != 0, true)

  // payload 应该是 "hello"
  let body_str = (try? @buf.utf8_bytes_to_string(Bytes::from_array(f1.payload))).unwrap_or(
    "",
  )
  assert_eq(body_str, "hello")
}


///|
test "http2: serve_once_body_streaming — streaming response DATA" {
  //println("=== http2 streaming server test ===")

  // 1. 构造“客户端 → 服务器”的字节流：
  //    preface + SETTINGS + HEADERS(GET /stream, END_STREAM=1)
  let pre = client_preface_bytes()
  let settings : Array[H2SettingKV] = []
  let sf = build_settings_frame(settings, false)
  let req_hs : Array[HpackHeader] = []
  req_hs.push({ name: ":method", value: "GET" })
  req_hs.push({ name: ":path", value: "/stream" })
  req_hs.push({ name: ":scheme", value: "https" })
  req_hs.push({ name: ":authority", value: "example.com" })

  // end_stream=true 表示请求没有 DATA 体
  let hdr_bytes = build_headers_frames_from_list(
    1,
    req_hs,
    true,
    max_frame_size=H2_DEFAULT_MAX_FRAME_SIZE,
  )
  let rx : Array[Byte] = []
  for b in pre {
    rx.push(b)
  }
  for b in sf {
    rx.push(b)
  }
  for b in hdr_bytes {
    rx.push(b)
  }

  // 2. in-memory transport
  let io = try @tsp.from_inmemory(rx) catch {
    _ => {
      assert_eq(true, false)
      return
    }
  } noraise {
    t => t
  }
  let cur = @tsp.buf_new()

  // 3. server 端 handler：返回一个两块的 Body::Stream
  let handler = fn(
    req : @cor.Request,
  ) -> (@cor.StatusCode, Map[String, String], @cor.Body, Bool) {
    if req.line.target != "/stream" {
      let hs : Map[String, String] = Map::new()
      let body : Array[Byte] = []
      return (@cor.StatusCode::NotFound, hs, @cor.Body::Bytes(body), false)
    }
    let hs : Map[String, String] = Map::new()
    hs.set("content-type", "text/plain")
    let mut step = 0
    let body = @cor.Body::Stream(fn() -> Result[(Array[Byte], Bool), String] {
      if step == 0 {
        step += 1
        let bs = @buf.string_to_utf8_bytes("part-1\n").to_array()
        Ok((bs, false))
      } else if step == 1 {
        step += 1
        let bs = @buf.string_to_utf8_bytes("part-2\n").to_array()
        Ok((bs, true))
      } else {
        let empty : Array[Byte] = []
        Ok((empty, true))
      }
    })
    (@cor.StatusCode::OK, hs, body, false)
  }

  // 4. 跑一轮 HTTP/2 单请求流式 server
  let r = serve_once_body_streaming(
    cur,
    io,
    handler,
    4096,
    max_frame_size=H2_DEFAULT_MAX_FRAME_SIZE,
  )
  match r {
    Ok(_) => ()
    Err(e) => {
      println("server error: " + @cor.error_to_string(e))
      assert_eq(true, false)
      return
    }
  }

  // 5. 取出 server 写出的响应字节，用新的 in-memory 连接来解析
  let resp_bytes = io.take_tx()
  let io2 = try @tsp.from_inmemory(resp_bytes) catch {
    _ => {
      assert_eq(true, false)
      return
    }
  } noraise {
    t => t
  }
  let cur2 = @tsp.buf_new()

  // 5.1 先读掉服务器发出的 SETTINGS ack（stream 0）
  let f0 = match
    read_frame(cur2, io2, 4096, max_frame_size=H2_DEFAULT_MAX_FRAME_SIZE) {
    Ok(x) => x
    Err(e) => {
      println("read first frame failed: " + e)
      assert_eq(true, false)
      return
    }
  }
  if f0.header.typ == H2_FRAME_SETTINGS {
    let (ack, _) = match parse_settings_frame(f0) {
      Ok(t) => t
      Err(e) => {
        println("parse settings ack failed: " + e)
        assert_eq(true, false)
        return
      }
    }
    // 必须是 ack
    assert_eq(ack, true)
  } else {
    //println("first frame is not SETTINGS, typ=" + f0.header.typ.to_string())
    assert_eq(true, false)
    return
  }

  // 5.2 现在才读响应 HEADERS(+CONTINUATION)
  let (info, hs) = match
    read_headers_as_list(
      cur2,
      io2,
      4096,
      max_frame_size=H2_DEFAULT_MAX_FRAME_SIZE,
    ) {
    Ok(t) => t
    Err(e) => {
      println("read response headers failed: " + e)
      assert_eq(true, false)
      return
    }
  }
  assert_eq(info.stream_id, 1)
  let mut has_status_200 = false
  for h in hs {
    if h.name == ":status" && h.value == "200" {
      has_status_200 = true
    }
  }
  assert_eq(has_status_200, true)

  // 6. 再读 DATA 帧，把 payload 拼起来
  let all : Array[Byte] = []
  let mut done = false
  let mut rounds2 = 0
  while !done {
    rounds2 += 1
    if rounds2 > 16 {
      println("too many DATA frames")
      assert_eq(true, false)
      return
    }
    let f = match
      read_frame(cur2, io2, 4096, max_frame_size=H2_DEFAULT_MAX_FRAME_SIZE) {
      Ok(x) => x
      Err(e) => {
        println("read_frame failed: " + e)
        assert_eq(true, false)
        return
      }
    }
    if f.header.typ == H2_FRAME_DATA {
      let mut i = 0
      while i < f.payload.length() {
        all.push(f.payload[i])
        i += 1
      }
      if (f.header.flags & H2_FLAGS_END_STREAM) != 0 {
        done = true
      }
    } else {
      // 其他帧 (WINDOW_UPDATE 等) 暂时忽略
    }
  }
  let body_str = (try? @buf.utf8_bytes_to_string(Bytes::from_array(all))).unwrap_or(
    "",
  )
  //println("streaming response body = '" + body_str + "'")
  assert_eq(body_str, "part-1\npart-2\n")
  //println("=== http2 streaming server test finished ===\n")
}


///|
test "h2: SETTINGS encode/decode roundtrip" {
  let kvs : Array[H2SettingKV] = []
  kvs.push({ id: 0x1, value: 0 })
  kvs.push({ id: 0x5, value: 16384 })
  let bytes = build_settings_frame(kvs, false)
  ////println("SETTINGS total bytes = " + bytes.length().to_string())
  ////println("SETTINGS head9 hex   = " + dbg_hex16(bytes)) 
  let io = (try? @tsp.from_inmemory(bytes)).unwrap()
  let cur = @tsp.buf_new()
  let rf = read_frame(cur, io, 4096) // ← 不再 unwrap
  match rf {
    Ok(f) => {
      assert_eq(f.header.typ, H2_FRAME_SETTINGS)
      assert_eq(f.header.stream_id, 0)
      let rps = parse_settings_frame(f) // ← 不再 unwrap
      match rps {
        Ok((ack, kvs2)) => {
          assert_eq(ack, false)
          assert_eq(kvs2.length(), 2)
          assert_eq(kvs2[0].id, 0x1)
          assert_eq(kvs2[0].value, 0)
          assert_eq(kvs2[1].id, 0x5)
          assert_eq(kvs2[1].value, 16384)
        }
        Err(e) => {
          ignore(e)
          ////println("parse_settings_frame failed: " + e)
          let a = true
          assert_eq(a, false)
          return
        }
      }
    }
    Err(e) => {
      ignore(e)
      ////println("read_frame failed: " + e)
      let a = true
      assert_eq(a, false)
      return
    }
  }
}

///|
test "h2: PING encode/decode (ack and no-ack)" {
  let opaque1 = @buf.string_to_utf8_bytes("12345678").to_array()

  // no-ack
  let b1 = build_ping_frame(opaque1, false)
  ////println("PING(no-ack) bytes = " + b1.length().to_string())
  ////println("PING(no-ack) head  = " + dbg_hex16(b1))
  let io1 = (try? @tsp.from_inmemory(b1)).unwrap()
  let cur1 = @tsp.buf_new()
  let r1 = read_frame(cur1, io1, 4096)
  match r1 {
    Ok(f1) => {
      let rp1 = parse_ping_frame(f1)
      match rp1 {
        Ok((ack1, p1)) => {
          assert_eq(ack1, false)
          assert_eq(p1, opaque1)
        }
        Err(e) => {
          ignore(e)
          ////println("parse_ping_frame (no-ack) failed: " + e)
          let a = true
          assert_eq(a, false)
          return
        }
      }
    }
    Err(e) => {
      ignore(e)
      ////println("read_frame (no-ack) failed: " + e)
      let a = true
      assert_eq(a, false)
      return
    }
  }

  // ack
  let b2 = build_ping_frame(opaque1, true)
  ////println("PING(ack)   bytes = " + b2.length().to_string())
  ////println("PING(ack)   head  = " + dbg_hex16(b2))
  let io2 = (try? @tsp.from_inmemory(b2)).unwrap()
  let cur2 = @tsp.buf_new()
  let r2 = read_frame(cur2, io2, 4096)
  match r2 {
    Ok(f2) => {
      let rp2 = parse_ping_frame(f2)
      match rp2 {
        Ok((ack2, p2)) => {
          assert_eq(ack2, true)
          assert_eq(p2, opaque1)
        }
        Err(e) => {
          ignore(e)
          ////println("parse_ping_frame (ack) failed: " + e)
          let a = true
          assert_eq(a, false)
          return
        }
      }
    }
    Err(e) => {
      ignore(e)
      ////println("read_frame (ack) failed: " + e)
      let a = true
      assert_eq(a, false)
      return
    }
  }
}

///|
test "h2: server accepts preface + SETTINGS then sends ACK" {
  let pre = client_preface_bytes()
  let cli_settings = build_settings_frame([], false)
  let inbound : Array[Byte] = []
  for b in pre {
    inbound.push(b)
  }
  for b in cli_settings {
    inbound.push(b)
  }
  ////println("SERVER inbound bytes = " + inbound.length().to_string())
  ////println("SERVER inbound head9 = " + dbg_hex16(inbound))
  let io = (try? @tsp.from_inmemory(inbound)).unwrap()
  let cur = @tsp.buf_new()
  let rk = h2_server_accept_and_ack(cur, io, 4096)
  match rk {
    Ok(kvs) => {
      assert_eq(kvs.length(), 0)
      let tx = io.take_tx()
      assert_eq(tx.length() >= 9, true)
      assert_eq(tx[3].to_int(), H2_FRAME_SETTINGS)
      assert_eq(tx[4].to_int() & 0x1, 1)
      assert_eq(tx[5].to_int() & 0x80, 0)
      assert_eq(
        tx[5].to_int() | tx[6].to_int() | tx[7].to_int() | tx[8].to_int(),
        0,
      )
    }
    Err(e) => {
      ignore(e)
      ////println("h2_server_accept_and_ack failed: " + e)
      let a = true
      assert_eq(a, false)
      return
    }
  }
}

// mini_roundtrip_test

///|
test "h2: minimal roundtrip GET → 200 + DATA('hello')" {
  // client → server 入站：preface + client SETTINGS + request HEADERS(stream 1, END_STREAM)
  let pre = client_preface_bytes()
  let cli_settings = build_settings_frame([], false)

  // 构造最小请求头：:method GET, :scheme http, :authority example.com, :path /
  let req_hs : Array[HpackHeader] = []
  req_hs.push({ name: ":method", value: "GET" })
  req_hs.push({ name: ":scheme", value: "http" })
  req_hs.push({ name: ":authority", value: "example.com" })
  req_hs.push({ name: ":path", value: "/" })
  let req_headers_bytes = build_headers_frames_from_list(1, req_hs, true)
  let inbound : Array[Byte] = []
  for b in pre {
    inbound.push(b)
  }
  for b in cli_settings {
    inbound.push(b)
  }
  for b in req_headers_bytes {
    inbound.push(b)
  }
  let io = (try? @tsp.from_inmemory(inbound)).unwrap()
  let cur = @tsp.buf_new()
  match h2_server_handle_get_hello(cur, io, 4096) {
    Ok(_) => ()
    Err(_e) => {
      //println("server handle failed: " + e)
      let a = true
      assert_eq(a, false)
      return
    }
  }

  // 取出 server 写回内容，解析：应为 SETTINGS(ACK) + HEADERS(:status 200, ...) + DATA("hello", END_STREAM)
  let tx = io.take_tx()
  let io2 = (try? @tsp.from_inmemory(tx)).unwrap()
  let cur2 = @tsp.buf_new()

  // 先读 SETTINGS ACK
  let fa = read_frame(cur2, io2, 4096).unwrap()
  assert_eq(fa.header.typ, H2_FRAME_SETTINGS)
  assert_eq(fa.header.stream_id, 0)
  assert_eq(fa.header.length, 0)
  assert_eq((fa.header.flags & H2_FLAGS_ACK) != 0, true)

  // 用桥接函数一次性读取并解码响应 HEADERS（内部会处理 CONTINUATION）
  let (info_resp, _) = read_headers_as_list(cur2, io2, 4096).unwrap()
  assert_eq(info_resp.stream_id, 1)
  assert_eq(info_resp.end_stream, false)
  // 如需校验内容，可加：
  // assert_eq(hdrs_resp[0].name, ":status")
  // assert_eq(hdrs_resp[0].value, "200")

  let f2 = read_frame(cur2, io2, 4096).unwrap()
  assert_eq(f2.header.typ, H2_FRAME_DATA)
  assert_eq((f2.header.flags & H2_FLAGS_END_STREAM) != 0, true)
  let s = (try? @buf.utf8_bytes_to_string(Bytes::from_array(f2.payload))).unwrap_or(
    "",
  )
  assert_eq(s, "hello")
}