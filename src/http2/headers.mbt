// 解析 HEADERS/CONTINUATION 头块（从首个 HEADERS 开始，一直读到 END_HEADERS）
// 返回：(info, 完整 header block fragment 原始字节)
// 说明：仅 HEADERS 允许 PADDED/PRIORITY；CONTINUATION 只允许 END_HEADERS。
///|
fn read_headers_block(
  cur : @tsp.BufCursor,
  io : @tsp.Transport,
  read_win : Int,
  max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE,
) -> Result[(H2HeadersInfo, Array[Byte]), String] {
  // 先读第一帧（必须是 HEADERS）
  let f0 = match read_frame(cur, io, read_win, max_frame_size~) {
    Ok(x) => x
    Err(e) => return Err(e)
  }
  if f0.header.typ != H2_FRAME_HEADERS {
    return Err("h2 headers: first frame not HEADERS")
  }
  let sid = f0.header.stream_id
  let flags0 = f0.header.flags
  let end_stream = (flags0 & H2_FLAGS_END_STREAM) != 0
  let padded = (flags0 & H2_FLAGS_PADDED) != 0
  let has_prio = (flags0 & H2_FLAGS_PRIORITY) != 0
  let mut off = 0
  let pl = f0.payload

  // 处理 PADDED：第一个字节是 pad length
  let mut pad_len = 0
  if padded {
    if pl.length() < 1 {
      return Err("h2 headers: padded but payload too short")
    }
    pad_len = pl[0].to_int() & 0xFF
    off = 1
    if pad_len > pl.length() - off {
      return Err("h2 headers: invalid pad length")
    }
  }
  let mut exclusive = false
  let mut dep_stream = 0
  let mut weight = 0
  if has_prio {
    if pl.length() - off < 5 {
      return Err("h2 headers: priority but payload too short")
    }
    let b0 = pl[off + 0].to_int() & 0xFF
    let b1 = pl[off + 1].to_int() & 0xFF
    let b2 = pl[off + 2].to_int() & 0xFF
    let b3 = pl[off + 3].to_int() & 0xFF
    let w = pl[off + 4].to_int() & 0xFF
    exclusive = (b0 & 0x80) != 0
    dep_stream = ((b0 & 0x7F) << 24) | (b1 << 16) | (b2 << 8) | b3
    weight = w + 1
    off += 5
  }

  // 取出首帧的 header block fragment（去掉右侧 padding）
  let mut first_limit = pl.length() - pad_len
  if first_limit < off {
    first_limit = off
  }
  let frag : Array[Byte] = []
  let mut i = off
  while i < first_limit {
    frag.push(pl[i])
    i += 1
  }
  let mut end_headers = (flags0 & H2_FLAGS_END_HEADERS) != 0

  // 若未收尾，继续读 CONTINUATION
  while !end_headers {
    let f = match read_frame(cur, io, read_win, max_frame_size~) {
      Ok(x) => x
      Err(e) => return Err(e)
    }
    if f.header.typ != H2_FRAME_CONTINUATION {
      return Err("h2 headers: expected CONTINUATION")
    }
    if f.header.stream_id != sid {
      return Err("h2 headers: continuation on different stream")
    }
    // CONTINUATION 不允许 PADDED / PRIORITY
    if (f.header.flags & (H2_FLAGS_PADDED | H2_FLAGS_PRIORITY)) != 0 {
      return Err("h2 headers: invalid flags on CONTINUATION")
    }
    // 整个 payload 都是 fragment
    let p = f.payload
    let mut j = 0
    while j < p.length() {
      frag.push(p[j])
      j += 1
    }
    end_headers = (f.header.flags & H2_FLAGS_END_HEADERS) != 0
  }
  let info : H2HeadersInfo = {
    stream_id: sid,
    end_stream,
    has_priority: has_prio,
    exclusive,
    dep_stream,
    weight,
  }
  Ok((info, frag))
}

// 读一个 HEADERS(+CONTINUATION...) 并用 HPACK 解码为键值数组

///|
fn read_headers_as_list(
  cur : @tsp.BufCursor,
  io : @tsp.Transport,
  read_win : Int,
  max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE,
) -> Result[(H2HeadersInfo, Array[HpackHeader]), String] {
  let (info, frag) = match
    read_headers_block(cur, io, read_win, max_frame_size~) {
    Ok(t) => t
    Err(e) => return Err(e)
  }
  let hs = match hpack_decode_block(frag) {
    Ok(v) => v
    Err(e) => return Err("hpack decode failed: " + e)
  }
  Ok((info, hs))
}

// 构造 HEADERS(+若干 CONTINUATION) 的一串帧字节（按 max_frame_size 自动切片）
// fragment: 传入“已经 HPACK 编码好的 header block bytes”
// 可选：end_stream 标志、priority(5B)，暂不支持 padding（保持简单）
//  如需 padding，后面可扩展（在首帧 payload 前插 1B padlen + pad bytes）。

// 无 PRIORITY 版本
///|
fn build_headers_frames(
  stream_id : Int,
  fragment : Array[Byte],
  end_stream : Bool,
  max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE,
) -> Array[Byte] {
  build_headers_frames_prio(
    stream_id,
    fragment,
    end_stream,
    max_frame_size,
    false,
    { exclusive: false, dep_stream: 0, weight: 16 },
  )
}

// 带 PRIORITY 的版本

///|
pub fn build_headers_frames_prio(
  stream_id : Int,
  fragment : Array[Byte],
  end_stream : Bool,
  max_frame_size : Int,
  has_priority : Bool,
  prio : H2Priority,
) -> Array[Byte] {
  // 计算首帧额外开销
  let mut first_overhead = 0
  if has_priority {
    first_overhead += 5
  }
  let mut remain = fragment.length()
  let mut idx = 0
  let out : Array[Byte] = []

  // 首帧：HEADERS 
  let first_room = max_frame_size - first_overhead
  let first_take = if remain <= first_room { remain } else { first_room }
  let mut flags = 0
  if end_stream {
    flags = flags | H2_FLAGS_END_STREAM
  }
  if has_priority {
    flags = flags | H2_FLAGS_PRIORITY
  }
  if first_take == remain {
    flags = flags | H2_FLAGS_END_HEADERS
  }
  let first_len = first_overhead + first_take
  let h0 : H2FrameHeader = {
    length: first_len,
    typ: H2_FRAME_HEADERS,
    flags,
    stream_id: stream_id & 0x7FFFFFFF,
  }
  let head0 = encode_frame_header(h0)

  // 写 PRIORITY 字段
  if has_priority {
    let dep = prio.dep_stream & 0x7FFFFFFF
    let mut b0 = (dep >> 24) & 0x7F
    if prio.exclusive {
      b0 = b0 | 0x80
    }
    head0.push(b0.to_byte())
    head0.push(((dep >> 16) & 0xFF).to_byte())
    head0.push(((dep >> 8) & 0xFF).to_byte())
    head0.push((dep & 0xFF).to_byte())
    let w = if prio.weight <= 0 {
      1
    } else if prio.weight > 256 {
      256
    } else {
      prio.weight
    }
    head0.push(((w - 1) & 0xFF).to_byte()) // on wire: weight-1
  }

  // 首片 fragment
  let mut k = 0
  while k < first_take {
    head0.push(fragment[idx + k])
    k += 1
  }
  idx += first_take
  remain -= first_take

  // 写入首帧
  let mut u = 0
  while u < head0.length() {
    out.push(head0[u])
    u += 1
  }

  // 后续 CONTINUATION
  while remain > 0 {
    let take = if remain <= max_frame_size { remain } else { max_frame_size }
    let c_flags = if take == remain { H2_FLAGS_END_HEADERS } else { 0 }
    let h : H2FrameHeader = {
      length: take,
      typ: H2_FRAME_CONTINUATION,
      flags: c_flags,
      stream_id: stream_id & 0x7FFFFFFF,
    }
    let head = encode_frame_header(h)
    let mut t = 0
    while t < take {
      head.push(fragment[idx + t])
      t += 1
    }
    idx += take
    remain -= take
    let mut z = 0
    while z < head.length() {
      out.push(head[z])
      z += 1
    }
  }
  out
}

// DATA 帧（仅构造；拆读直接用 read_frame）
// 把 payload 切成若干 DATA 帧；最后一帧可置 END_STREAM

///|
fn build_data_frames(
  stream_id : Int,
  payload : Array[Byte],
  end_stream : Bool,
  max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE,
) -> Array[Byte] {
  let out : Array[Byte] = []
  let mut remain = payload.length()
  let mut idx = 0
  while remain > 0 || (remain == 0 && idx == 0) {
    let take = if remain == 0 {
      0
    } else if remain <= max_frame_size {
      remain
    } else {
      max_frame_size
    }
    let last = idx + take >= payload.length()
    let flags = if last && end_stream { H2_FLAGS_END_STREAM } else { 0 }
    let h : H2FrameHeader = {
      length: take,
      typ: H2_FRAME_DATA,
      flags,
      stream_id: stream_id & 0x7FFFFFFF,
    }
    let head = encode_frame_header(h)
    let mut i = 0
    while i < take {
      head.push(payload[idx + i])
      i += 1
    }
    idx += take
    remain -= take
    let mut j = 0
    while j < head.length() {
      out.push(head[j])
      j += 1
    }
    if take == 0 {
      break
    }
  }
  out
}


///|
fn encode_block_with_huffman(
  hs : Array[HpackHeader],
  use_huffman_for_name : Bool,
  use_huffman_for_value : Bool,
) -> Array[Byte] {
  let block : Array[Byte] = []
  let mut i = 0
  while i < hs.length() {
    let it = hs[i]
    // 对 name 是否启用 Huffman：只有当 name 不在静态表时才会真正使用字符串编码
    let part = hpack_encode_literal_noindex(
      it.name,
      it.value,
      use_huffman=if use_huffman_for_name || use_huffman_for_value {
        true
      } else {
        false
      },
    )
    let mut j = 0
    while j < part.length() {
      block.push(part[j])
      j += 1
    }
    i += 1
  }
  block
}



///|
test "h2: HEADERS single-frame roundtrip" {
  let sid = 1
  // 伪 header block：随手给点字节（后续接 HPACK）
  let frag = @buf.string_to_utf8_bytes("abcd").to_array()
  let bytes = build_headers_frames(sid, frag, false)
  let io = (try? @tsp.from_inmemory(bytes)).unwrap()
  let cur = @tsp.buf_new()
  let (info, got) = read_headers_block(cur, io, 4096).unwrap()
  assert_eq(info.stream_id, sid)
  assert_eq(info.end_stream, false)
  assert_eq(info.has_priority, false)
  let s = (try? @buf.utf8_bytes_to_string(Bytes::from_array(got))).unwrap_or("")
  assert_eq(s, "abcd")
}

///|
test "h2: HEADERS + CONTINUATION reassemble" {
  let sid = 1
  // 制造一个超过默认帧长的小片段（用非常小的 max_frame_size 来强制切片）
  let frag = @buf.string_to_utf8_bytes("0123456789abcdefghijklmnopqrstuvwxyz").to_array()
  let maxfs = 10 // 故意很小，触发 continuation
  let bytes = build_headers_frames(sid, frag, true, max_frame_size=maxfs) // END_STREAM=true 也行
  let io = (try? @tsp.from_inmemory(bytes)).unwrap()
  let cur = @tsp.buf_new()
  let (info, got) = read_headers_block(cur, io, 4096, max_frame_size=maxfs).unwrap()
  assert_eq(info.stream_id, sid)
  assert_eq(info.end_stream, true)
  let s = (try? @buf.utf8_bytes_to_string(Bytes::from_array(got))).unwrap_or("")
  assert_eq(s, "0123456789abcdefghijklmnopqrstuvwxyz")
}

///|
test "hpack: decode simple literals (noindex)" {
  let block : Array[Byte] = []
  let a = hpack_encode_literal_noindex(":method", "GET")
  for b in a {
    block.push(b)
  }
  let b2 = hpack_encode_literal_noindex(":path", "/")
  for b in b2 {
    block.push(b)
  }
  let hs = hpack_decode_block(block).unwrap()
  assert_eq(hs.length(), 2)
  assert_eq(hs[0].name, ":method")
  assert_eq(hs[0].value, "GET")
  assert_eq(hs[1].name, ":path")
  assert_eq(hs[1].value, "/")
}

///|
test "hpack: indexed field" {
  // 直接用静态索引 8 => :status: 200
  let bytes : Array[Byte] = []
  // 写 1xxxxxxx，N=7 整数 8
  // 8 fits prefix -> single byte: 10001000 (0x88)
  let a = 0x88
  bytes.push(a.to_byte())
  let hs = hpack_decode_block(bytes).unwrap()
  assert_eq(hs.length(), 1)
  assert_eq(hs[0].name, ":status")
  assert_eq(hs[0].value, "200")
}

///|
test "h2: HEADERS roundtrip via HPACK (no-index)" {
  // 构造一个最小请求头集（无 Huffman、no-index）
  let req_hs : Array[HpackHeader] = []
  req_hs.push({ name: ":method", value: "GET" })
  req_hs.push({ name: ":scheme", value: "http" })
  req_hs.push({ name: ":authority", value: "example.com" })
  req_hs.push({ name: ":path", value: "/" })
  req_hs.push({ name: "accept", value: "*/*" })
  let bytes = build_headers_frames_from_list(1, req_hs, false)
  let io = (try? @tsp.from_inmemory(bytes)).unwrap()
  let cur = @tsp.buf_new()
  let (info, got) = read_headers_as_list(cur, io, 4096).unwrap()
  assert_eq(info.stream_id, 1)
  assert_eq(info.end_stream, false)
  assert_eq(got.length() >= 4, true)
  assert_eq(got[0].name, ":method")
  assert_eq(got[0].value, "GET")
  assert_eq(got[1].name, ":scheme")
  assert_eq(got[1].value, "http")
}



//  不启用 Huffman：headers roundtrip

///|
test "hpack: no-huffman headers encode → decode roundtrip" {
  let hs : Array[HpackHeader] = []
  hs.push({ name: ":method", value: "GET" })
  hs.push({ name: ":scheme", value: "http" })
  hs.push({ name: ":authority", value: "example.com" })
  hs.push({ name: ":path", value: "/index.html" })
  hs.push({ name: "user-agent", value: "MoonbitHTTP/0.1" })

  // 不启用 Huffman（走你原本路径）
  let bytes = build_headers_frames_from_list(1, hs, true)
  let io = (try? @tsp.from_inmemory(bytes)).unwrap()
  let cur = @tsp.buf_new()
  let (_info, got) = read_headers_as_list(cur, io, 4096).unwrap()

  // 关键断言
  assert_eq(got.length() >= 5, true)
  assert_eq(got[0].name, ":method")
  assert_eq(got[0].value, "GET")
  assert_eq(got[3].name, ":path")
  assert_eq(got[3].value, "/index.html")
  // user-agent roundtrip
  let mut ua_ok = false
  for h in got {
    if h.name == "user-agent" && h.value == "MoonbitHTTP/0.1" {
      ua_ok = true
    }
  }
  assert_eq(ua_ok, true)
}

// 2) 仅对“值”尝试启用 Huffman：即使表没全，也会自动回退；roundtrip 必须一致

///|
test "hpack: (try) huffman for values → decode roundtrip" {
  let hs : Array[HpackHeader] = []
  hs.push({ name: ":method", value: "GET" })
  hs.push({ name: ":scheme", value: "http" })
  hs.push({ name: ":authority", value: "example.com" })
  hs.push({ name: ":path", value: "/" })
  hs.push({ name: "cookie", value: "///" })
  let block = encode_block_with_huffman(hs, false, true)
  let bytes = build_headers_frames(
    1,
    block,
    true,
    max_frame_size=H2_DEFAULT_MAX_FRAME_SIZE,
  )
  let io = (try? @tsp.from_inmemory(bytes)).unwrap()
  let cur = @tsp.buf_new()
  match
    read_headers_as_list(
      cur,
      io,
      4096,
      max_frame_size=H2_DEFAULT_MAX_FRAME_SIZE,
    ) {
    Ok((_info, got)) => {
      let mut cookie_ok = false
      for h in got {
        if h.name == "cookie" && h.value == "///" {
          cookie_ok = true
        }
      }
      assert_eq(cookie_ok, true)
      assert_eq(got[0].name, ":method")
      assert_eq(got[0].value, "GET")
    }
    Err(_e) => {
      //println("read_headers_as_list failed: " + e)
      let a = true
      assert_eq(a, false)
    }
  }
}

// 3) 名字不在静态表时，(try) huffman（会针对 name/value 一起尝试；不足时回退），roundtrip 一致

///|
test "hpack: literal-name with (try) huffman → decode roundtrip" {
  let hs : Array[HpackHeader] = []
  hs.push({ name: "x-test", value: "v/1" }) // name 不在静态表；value 含 '/'
  hs.push({ name: ":status", value: "200" })
  let block = encode_block_with_huffman(hs, true, true)
  let bytes = build_headers_frames(1, block, true)
  let io = (try? @tsp.from_inmemory(bytes)).unwrap()
  let cur = @tsp.buf_new()
  let (_info, got) = read_headers_as_list(cur, io, 4096).unwrap()
  let mut x_ok = false
  let mut s_ok = false
  for h in got {
    if h.name == "x-test" && h.value == "v/1" {
      x_ok = true
    }
    if h.name == ":status" && h.value == "200" {
      s_ok = true
    }
  }
  assert_eq(x_ok, true)
  assert_eq(s_ok, true)
}
