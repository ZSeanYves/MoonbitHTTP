// === 内部工具 ===
///|
fn parse_status_from_headers(
  hs : Array[HpackHeader],
) -> Result[(@cor.Status, Map[String, String]), String] {
  let hdrs : Map[String, String] = Map::new()
  let mut code : Int = 0
  let mut i = 0
  while i < hs.length() {
    let h = hs[i]
    if h.name == ":status" {
      // 解析数字
      let bs = @buf.string_to_utf8_bytes(h.value).to_array()
      let mut j = 0
      let mut n : Int = 0
      while j < bs.length() {
        let d = bs[j].to_int()
        if d < 48 || d > 57 {
          return Err("invalid :status value: " + h.value)
        }
        n = n * 10 + (d - 48)
        j += 1
      }
      code = n
    } else {
      hdrs.set(h.name, h.value)
    }
    i += 1
  }
  if code == 0 {
    return Err("missing :status header")
  }
  // reason 先用默认的
  let st = @cor.make_status(code, "")
  Ok((st, hdrs))
}

/// 一个极简握手：
/// 发送 client preface + SETTINGS (kvs 可以为空)
/// 读取服务端首个 SETTINGS（必须是 SETTINGS 且非 ACK）
/// 回 ACK 帧
///
/// PS：这里假设服务器严格遵守“首帧是 SETTINGS”,若有 SETTINGS ack，在 read_response 阶段再遇到时会忽略
///|
fn h2_client_handshake(
  cur : @tsp.BufCursor,
  io : @tsp.Transport,
  read_win : Int,
  client_settings : Array[H2SettingKV],
  max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE,
) -> Result[Unit, String] {
  match h2_client_start(io, client_settings) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let f = match read_frame(cur, io, read_win, max_frame_size~) {
    Ok(x) => x
    Err(e) => return Err("h2 client handshake: read settings failed: " + e)
  }
  let (ack, _kvs) = match parse_settings_frame(f) {
    Ok(t) => t
    Err(e) => return Err("h2 client handshake: parse settings failed: " + e)
  }
  if ack {
    return Err("h2 client handshake: unexpected SETTINGS ack from server")
  }
  let ack_bytes = build_settings_frame([], true)
  try io.write_all(ack_bytes) catch {
    _ => return Err("h2 client handshake: write ack failed")
  } noraise {
    _ => ()
  }
  Ok(())
}

/// 读取一个简单响应：
///|
fn read_reponse(
  cur : @tsp.BufCursor,
  io : @tsp.Transport,
  limits : @cor.Limits,
  stream_id : Int,
  max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE,
) -> Result[@cor.Response, String] {
  let read_win = limits.read_win

  // 读响应 HEADERS
  let (info, hs_list) = match
    read_headers_as_list(cur, io, read_win, max_frame_size~) {
    Ok(t) => t
    Err(e) => return Err("h2 client: read response headers failed: " + e)
  }
  if info.stream_id != stream_id {
    return Err("h2 client: response headers on unexpected stream")
  }
  let (status, hdrs) = match parse_status_from_headers(hs_list) {
    Ok(t) => t
    Err(e) => return Err("h2 client: " + e)
  }

  // 若 END_STREAM=1，则无 body
  if info.end_stream {
    let resp : @cor.Response = { status, headers: hdrs, body: @cor.Body::Empty }
    return Ok(resp)
  }

  // 否则：读取 DATA 帧直到 END_STREAM
  let body : Array[Byte] = []
  let mut total = 0
  let mut done = false
  while !done {
    let f = match read_frame(cur, io, read_win, max_frame_size~) {
      Ok(x) => x
      Err(e) => return Err("h2 client: read frame failed: " + e)
    }
    if f.header.stream_id == stream_id && f.header.typ == H2_FRAME_DATA {
      // DATA 帧：累积 payload
      let p = f.payload
      total += p.length()
      if total > limits.max_body {
        return Err("h2 client: response body too large")
      }
      let mut i = 0
      while i < p.length() {
        body.push(p[i])
        i += 1
      }
      if (f.header.flags & H2_FLAGS_END_STREAM) != 0 {
        done = true
      }
      continue
    }

    // 其他流上的控制帧：忽略或做极简处理
    if f.header.stream_id == 0 {
      // SETTINGS ack / PING / WINDOW_UPDATE / GOAWAY 等
      if f.header.typ == H2_FRAME_SETTINGS {
        let (_, _kvs) = match parse_settings_frame(f) {
          Ok(t) => t
          Err(_e) => (false, [])
        }
        // ack_more==true 表示这是某次 SETTINGS ack，忽略即可
      } else if f.header.typ == H2_FRAME_PING {
        // 若对方 ping ，接回 ack（简化：忽略）
        // TODO:未来增加自动 ack
      }
      // 其他类型暂时全部忽略
      continue
    }

    // TODO:未来支持 trailing HEADERS
    if f.header.stream_id == stream_id && f.header.typ == H2_FRAME_HEADERS {
      // 最小实现：直接报错（后续可以扩展为读取 trailing headers）
      return Err("h2 client: trailing HEADERS not supported yet")
    }

    // 其他帧：忽略
  }
  let resp : @cor.Response = {
    status,
    headers: hdrs,
    body: @cor.Body::Bytes(body),
  }
  Ok(resp)
}


///|
/// HTTP/2: 以 streaming 方式读取响应：
fn read_response_streaming(
  io : @tsp.Transport,
  max_headers : Int,
  max_line : Int,
  read_win : Int,
  max_body : Int,
  stream_chunk? : Int = H2_DEFAULT_MAX_FRAME_SIZE,
) -> Result[@cor.Response, String] {
  // TODO：当前实现中暂未用到，未来扩展
  ignore(max_line)
  let cur = @tsp.buf_new()
  let max_frame_size = H2_DEFAULT_MAX_FRAME_SIZE
  let (info, hs_list) = match
    read_headers_as_list(cur, io, read_win, max_frame_size~) {
    Ok(t) => t
    Err(e) => return Err(e)
  }
  if hs_list.length() > max_headers {
    return Err("too many headers in h2 response")
  }

  // 从 header 列表中提取 :status + 其它普通头
  let mut code : Int = 0
  let mut has_status = false
  let hdr_map : Map[String, String] = Map::new()
  let mut i = 0
  while i < hs_list.length() {
    let h = hs_list[i]
    if h.name == ":status" {
      let s = h.value
      let bs = @buf.string_to_utf8_bytes(s).to_array()
      if bs.length() == 0 {
        return Err("h2: empty :status")
      }
      let mut j = 0
      let mut n : Int = 0
      while j < bs.length() {
        let d = bs[j].to_int()
        if d < 48 || d > 57 {
          return Err("h2: invalid :status '" + s + "'")
        }
        n = n * 10 + (d - 48)
        j += 1
      }
      code = n
      has_status = true
    } else {
      hdr_map.set(h.name, h.value)
    }
    i += 1
  }
  if !has_status {
    return Err("h2: missing :status in response headers")
  }
  let st : @cor.Status = @cor.make_status(code, "")

  // 若 HEADERS 自身带 END_STREAM，则无 body
  if info.end_stream {
    let resp : @cor.Response = {
      status: st,
      headers: hdr_map,
      body: @cor.Body::Empty,
    }
    return Ok(resp)
  }

  // 否则：构造 streaming body，内部按 DATA 帧逐步读取
  let chunk_limit = if stream_chunk <= 0 {
    H2_DEFAULT_MAX_FRAME_SIZE
  } else {
    stream_chunk
  }
  let mut finished = false
  let mut total_body : Int = 0
  let mut saw_end_stream = false
  let mut pending : Array[Byte] = []
  let body = @cor.Body::Stream(fn() -> Result[(Array[Byte], Bool), String] {
    if finished {
      let empty : Array[Byte] = []
      return Ok((empty, true))
    }

    // 如果还有挂起数据，先从 pending 中按 chunk_limit 拆一块出来
    if pending.length() > 0 {
      let take = if pending.length() <= chunk_limit {
        pending.length()
      } else {
        chunk_limit
      }
      let chunk : Array[Byte] = []
      let mut i = 0
      while i < take {
        chunk.push(pending[i])
        i += 1
      }
      // 剩余部分重新写回 pending
      let rest : Array[Byte] = []
      let mut j = take
      while j < pending.length() {
        rest.push(pending[j])
        j += 1
      }
      pending = rest
      total_body += chunk.length()
      if total_body > max_body {
        return Err("h2: response body too large")
      }
      let done = saw_end_stream && pending.length() == 0
      if done {
        finished = true
      }
      return Ok((chunk, done))
    }

    // pending 为空，需要继续从底层读帧
    while true {
      if saw_end_stream {
        finished = true
        let empty : Array[Byte] = []
        return Ok((empty, true))
      }
      let fr = match read_frame(cur, io, read_win, max_frame_size~) {
        Ok(x) => x
        Err(e) => return Err(e)
      }
      if fr.header.typ == H2_FRAME_DATA {
        // DATA 帧：拿到 payload，记录 END_STREAM
        let p = fr.payload
        let mut k = 0
        while k < p.length() {
          pending.push(p[k])
          k += 1
        }
        if (fr.header.flags & H2_FLAGS_END_STREAM) != 0 {
          saw_end_stream = true
        }
        if pending.length() == 0 {
          continue
        }
        let take = if pending.length() <= chunk_limit {
          pending.length()
        } else {
          chunk_limit
        }
        let chunk : Array[Byte] = []
        let mut i = 0
        while i < take {
          chunk.push(pending[i])
          i += 1
        }
        let rest : Array[Byte] = []
        let mut j = take
        while j < pending.length() {
          rest.push(pending[j])
          j += 1
        }
        pending = rest
        total_body += chunk.length()
        if total_body > max_body {
          return Err("h2: response body too large")
        }
        let done = saw_end_stream && pending.length() == 0
        if done {
          finished = true
        }
        return Ok((chunk, done))
      } else if fr.header.typ == H2_FRAME_HEADERS {
        // 作为 trailing headers：暂时只关心 END_STREAM
        if (fr.header.flags & H2_FLAGS_END_STREAM) != 0 {
          saw_end_stream = true
        }
        // 目前忽略 trailing header 内容
        continue
      } else {
        // 其它帧先忽略（WINDOW_UPDATE / SETTINGS / PING / GOAWAY ...）
        continue
      }
    }
    let empty2 : Array[Byte] = []
    Ok((empty2, true))
  })
  let resp : @cor.Response = { status: st, headers: hdr_map, body }
  Ok(resp)
}


// === 对外 API：GET / POST ===

///|
pub fn get(
  io : @tsp.Transport,
  target : String,
  authority : String,
  extra_headers : Map[String, String],
  limits : @cor.Limits,
  scheme? : String = "http",
) -> Result[@cor.Response, String] {
  let cur = @tsp.buf_new()
  let client_settings : Array[H2SettingKV] = [] // 暂不发送额外 SETTINGS 参数
  match h2_client_handshake(cur, io, limits.read_win, client_settings) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }

  // 2) 构造 HEADERS（不带 body，END_STREAM=1）
  let hs : Array[HpackHeader] = []
  // 伪头，顺序必须：:method, :path, :scheme, :authority
  hs.push({ name: ":method", value: "GET" })
  hs.push({ name: ":path", value: target })
  hs.push({ name: ":scheme", value: scheme })
  hs.push({ name: ":authority", value: authority })

  // 普通头：来自 extra_headers
  for k in extra_headers.keys() {
    let v = extra_headers.get(k).unwrap_or("")
    let name = @cor.norm_key(k)
    hs.push({ name, value: v })
  }

  // header block → HEADERS(+CONTINUATION) 帧
  let hdr_bytes = build_headers_frames_from_list(
    1,
    hs,
    true, // END_STREAM = true（无 body）
    max_frame_size=H2_DEFAULT_MAX_FRAME_SIZE,
  )
  try io.write_all(hdr_bytes) catch {
    _ => return Err("h2 client: write request headers failed")
  } noraise {
    _ => ()
  }
  read_reponse(cur, io, limits, 1, max_frame_size=H2_DEFAULT_MAX_FRAME_SIZE)
}

///|
/// HTTP/2: GET — streaming 版本
/// 约定：调用前已经完成 h2_client_start（preface+SETTINGS 交握）
pub fn get_streaming(
  io : @tsp.Transport,
  path : String,
  authority : String,
  extra_headers : Map[String, String],
  limits : @cor.Limits,
  stream_chunk? : Int = H2_DEFAULT_MAX_FRAME_SIZE,
) -> Result[@cor.Response, String] {
  let hs : Array[HpackHeader] = []
  hs.push({ name: ":method", value: "GET" })
  hs.push({ name: ":path", value: path })
  hs.push({ name: ":scheme", value: "http" })
  hs.push({ name: ":authority", value: authority })

  // 追加用户自定义头
  for k in extra_headers.keys() {
    let v = extra_headers.get(k).unwrap_or("")
    // 按约定：HTTP/2 头部一般小写；你现在的静态表里也是小写
    let name = k // 如果你想强制小写，可以在这里做 to_lower
    hs.push({ name, value: v })
  }

  // 2) 构造 HEADERS(+CONTINUATION) 帧字节，并设置 END_STREAM=1（无 request body）
  let hdr_bytes = build_headers_frames_from_list(
    1, // stream_id: 简单客户端用 1
    hs,
    true, // end_stream: 请求端无 body
    max_frame_size=limits.max_line, // 用 max_line 作为最大帧长上限也可以
  )
  try io.write_all(hdr_bytes) catch {
    _ => return Err("h2 client: write request headers failed")
  } noraise {
    _ => ()
  }
  read_response_streaming(
    io,
    limits.max_headers,
    limits.max_line,
    limits.read_win,
    limits.max_body,
    stream_chunk~,
  )
}


///|
pub fn post(
  io : @tsp.Transport,
  target : String,
  authority : String,
  body : Array[Byte],
  content_type : String,
  extra_headers : Map[String, String],
  limits : @cor.Limits,
  scheme? : String = "http",
) -> Result[@cor.Response, String] {
  let cur = @tsp.buf_new()
  let client_settings : Array[H2SettingKV] = []

  match h2_client_handshake(cur, io, limits.read_win, client_settings) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }

  // 2) 构造 HEADERS（有 body，END_STREAM=0）
  let hs : Array[HpackHeader] = []
  hs.push({ name: ":method", value: "POST" })
  hs.push({ name: ":path", value: target })
  hs.push({ name: ":scheme", value: scheme })
  hs.push({ name: ":authority", value: authority })

  // 必要头：content-type / content-length
  hs.push({ name: "content-type", value: content_type })
  hs.push({ name: "content-length", value: body.length().to_string() })

  // 额外头
  for k in extra_headers.keys() {
    let v = extra_headers.get(k).unwrap_or("")
    let name = @cor.norm_key(k)
    // 避免重复 content-type / content-length
    if name == "content-type" || name == "content-length" {
      continue
    }
    hs.push({ name, value: v })
  }

  let hdr_bytes = build_headers_frames_from_list(
    1,
    hs,
    false, // END_STREAM = false（后面还有 DATA）
    max_frame_size=H2_DEFAULT_MAX_FRAME_SIZE,
  )

  // 3) 构造 DATA 帧，END_STREAM = true
  let data_bytes = build_data_frames(
    1,
    body,
    true, // END_STREAM 在 DATA 上
    max_frame_size=H2_DEFAULT_MAX_FRAME_SIZE,
  )

  try io.write_all(hdr_bytes) catch {
    _ => return Err("h2 client: write request headers failed")
  } noraise {
    _ => ()
  }
  try io.write_all(data_bytes) catch {
    _ => return Err("h2 client: write request body failed")
  } noraise {
    _ => ()
  }

  // 4) 读取响应
  read_reponse(cur, io, limits, 1, max_frame_size=H2_DEFAULT_MAX_FRAME_SIZE)
}


/// 一个最小的 “GET hello” 整合测试：
/// PS：这里不走真实的 request/response 往返顺序，只是验证编码+解码路径。
///|
test "http2 client: GET — simple 200 hello" {
  // 1) 预构造“服务端”要发给客户端的字节流
  let server_settings : Array[H2SettingKV] = []
  let settings_bytes = build_settings_frame(server_settings, false)

  let hs_resp : Array[HpackHeader] = []
  hs_resp.push({ name: ":status", value: "200" })
  hs_resp.push({ name: "content-type", value: "text/plain" })
  hs_resp.push({ name: "content-length", value: "5" })
  let headers_bytes = build_headers_frames_from_list(
    1,
    hs_resp,
    false, // END_STREAM = false，后面还有 DATA
    max_frame_size=H2_DEFAULT_MAX_FRAME_SIZE,
  )

  let body = @buf.string_to_utf8_bytes("hello").to_array()
  let data_bytes = build_data_frames(1, body, true, max_frame_size=H2_DEFAULT_MAX_FRAME_SIZE)

  let all_server_bytes : Array[Byte] = []
  for b in settings_bytes {
    all_server_bytes.push(b)
  }
  for b in headers_bytes {
    all_server_bytes.push(b)
  }
  for b in data_bytes {
    all_server_bytes.push(b)
  }

  // 2) 用 in-memory transport 预置 rx
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
  io.push_rx(all_server_bytes)

  // 3) 调用 http2 client get
  let limits : @cor.Limits = {
    max_headers: 64,
    max_line: 8192,
    read_win: 4096,
    max_body: 1024 * 1024,
  }
  let extra : Map[String, String] = Map::new()

  let resp = match get(io, "/hello", "example.com", extra, limits) {
    Ok(r) => r
    Err(e) => {
      // 触发失败
      assert_eq(e.length() >= 0, false)
      return
    }
  }

  assert_eq(resp.status.code, 200)

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

  // 4) 可选：检查客户端写出去的大致结构（preface + SETTINGS + HEADERS）
  let tx = io.take_tx()
  let txs = (try? @buf.utf8_bytes_to_string(Bytes::from_array(tx))).unwrap_or(
    "",
  )
  // 这里只看一下前言是否存在（PRIx开头）
  assert_eq(@cor.str_contains(txs, "PRI * HTTP/2.0"), true)
}

///|
test "h2 client: streaming — headers + data" {
  // 构造响应 HEADERS（stream 1，:status 200 + content-type）
  let hs : Array[HpackHeader] = []
  hs.push({ name: ":status", value: "200" })
  hs.push({ name: "content-type", value: "text/plain" })
  let hdr_bytes = build_headers_frames_from_list(
    1,
    hs,
    false, // END_STREAM = false，后面还有 DATA
    max_frame_size=H2_DEFAULT_MAX_FRAME_SIZE,
  )

  // 构造 DATA("hello world")，带 END_STREAM
  let body_bytes = @buf.string_to_utf8_bytes("hello world").to_array()
  let data_bytes = build_data_frames(
    1,
    body_bytes,
    true, // END_STREAM = true
    max_frame_size=H2_DEFAULT_MAX_FRAME_SIZE,
  )

  // in-memory Transport：把 HEADERS + DATA 推到 rx 里，模拟服务端发回
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
  io.push_rx(hdr_bytes)
  io.push_rx(data_bytes)

  // 复用 HTTP/1 的 Limits 结构（max_line 在 h2 里实际没用到）
  let limits : @cor.Limits = {
    max_headers: 32,
    max_line: 0,
    read_win: 4096,
    max_body: 1 * 1024 * 1024,
  }

  let resp = match
    read_response_streaming(
      io,
      limits.max_headers,
      limits.max_line,
      limits.read_win,
      limits.max_body,
      stream_chunk=5,
    ) {
    Ok(r) => r
    Err(e) => {
      assert_eq(e.length() >= 0, false)
      return
    }
  }

  // 校验状态码和头部
  assert_eq(resp.status.code, 200)
  let ct = resp.headers.get("content-type").unwrap_or("")
  assert_eq(ct, "text/plain")

  // 校验 body 是 streaming，并且能拼出 "hello world"
  match resp.body {
    @cor.Body::Stream(next) => {
      let buf_all : Array[Byte] = []
      let mut rounds = 0
      while true {
        rounds += 1
        if rounds > 10 {
          // 读太多轮还没 done，说明有问题
          let a = true
          assert_eq(a, false)
          return
        }
        let (chunk, done) = match next() {
          Ok(p) => p
          Err(e) => {
            assert_eq(e.length() >= 0, false)
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
      let s_all = (try? @buf.utf8_bytes_to_string(Bytes::from_array(buf_all))).unwrap_or(
        "",
      )
      assert_eq(s_all, "hello world")
    }
    _ => {
      let a = true
      assert_eq(a, false) // 应该是 Body::Stream
    }
  }
}

///|
test "h2 client: streaming — headers with END_STREAM (no body)" {
  // 构造只有 HEADERS 的响应，END_STREAM = true
  let hs : Array[HpackHeader] = []
  hs.push({ name: ":status", value: "204" })
  hs.push({ name: "content-type", value: "text/plain" })

  let hdr_bytes = build_headers_frames_from_list(
    1,
    hs,
    true, // END_STREAM = true，直接表示没有 body
    max_frame_size=H2_DEFAULT_MAX_FRAME_SIZE,
  )

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
  io.push_rx(hdr_bytes)

  let limits : @cor.Limits = {
    max_headers: 32,
    max_line: 0,
    read_win: 4096,
    max_body: 1 * 1024 * 1024,
  }

  let resp = match read_response_streaming(
    io,
    limits.max_headers,
    limits.max_line,
    limits.read_win,
    limits.max_body,
    stream_chunk=8 * 1024,
  ) {
    Ok(r) => r
    Err(e) => {
      assert_eq(e.length() >= 0, false)
      return
    }
  }

  // :status 204
  assert_eq(resp.status.code, 204)
  let ct = resp.headers.get("content-type").unwrap_or("")
  assert_eq(ct, "text/plain")

  // 必须是 Empty，而不是 Bytes/Stream
  match resp.body {
    @cor.Body::Empty => ()
    _ => {
      let a = true
      assert_eq(a, false)
    }
  }
}
