//Tools：读写（局部实现，避免依赖 http1）
// 对 encoder 和 read 的补丁：
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
pub fn encode_frame_header(h : H2FrameHeader) -> Array[Byte] {
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
pub fn decode_frame_header(
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
  //println(
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
  //println(
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
pub fn client_preface_bytes() -> Array[Byte] {
  @buf.string_to_utf8_bytes(H2_CLIENT_PREFACE).to_array()
}

// 服务器侧校验：严格读取并仅消费 24 字节前言，剩余字节留在 cur 里
pub fn read_and_check_client_preface(
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
  //println("after preface, cur_have=" + cur.buf_len().to_string())
  Ok(())
}




// 编码 SETTINGS 的 payload（不含帧头）
pub fn encode_settings_payload(kvs : Array[H2SettingKV]) -> Array[Byte] {
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
pub fn decode_settings_payload(
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
pub fn build_ping_frame(opaque8 : Array[Byte], ack : Bool) -> Array[Byte] {
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
pub fn build_goaway_frame(
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
pub fn parse_settings_frame(
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
pub fn parse_ping_frame(f : H2Frame) -> Result[(Bool, Array[Byte]), String] {
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
pub fn build_window_update_frame(
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

pub fn parse_window_update_increment(f : H2Frame) -> Result[Int, String] {
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
pub fn build_rst_stream_frame(stream_id : Int, error_code : Int) -> Array[Byte] {
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

pub fn parse_rst_stream_error(f : H2Frame) -> Result[Int, String] {
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


pub fn h2_client_start(
  io : @tsp.Transport,
  settings : Array[H2SettingKV],
) -> Result[Unit, String] {
  // 发送前言
  let pre = client_preface_bytes()
  match (try? io.write_all(pre)) {
    Ok(_) => ()
    Err(_) => return Err("write client preface failed")
  }
  // 发送 SETTINGS
  let sf = build_settings_frame(settings, false)
  match (try? io.write_all(sf)) {
    Ok(_) => Ok(())
    Err(_) => Err("write client settings failed")
  }
}


pub fn h2_server_accept_and_ack(
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
  match (try? io.write_all(ack_bytes)) {
    Ok(_) => ()
    Err(_) => return Err("write settings ack failed")
  }
  Ok(kvs)
}

// 服务器一次完整处理：preface+SETTINGS(ack) → 读取请求 HEADERS → 回 200 和 DATA("hello")
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
  match (try? io.write_all(hdr_bytes)) {
    Ok(_) => ()
    Err(_) => return Err("write response headers failed")
  }
  match (try? io.write_all(data_bytes)) {
    Ok(_) => ()
    Err(_) => return Err("write response data failed")
  }
  Ok(())
}
