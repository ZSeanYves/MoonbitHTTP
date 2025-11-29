// 解析 HEADERS/CONTINUATION 头块（从首个 HEADERS 开始，一直读到 END_HEADERS）
// 返回：(info, 完整 header block fragment 原始字节)
// 说明：仅 HEADERS 允许 PADDED/PRIORITY；CONTINUATION 只允许 END_HEADERS。
///|
pub fn read_headers_block(
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
pub fn read_headers_as_list(
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
// fragment: 传入“已经 HPACK 编码好的 header block bytes”（这一步我们后续再做）。
// 可选：end_stream 标志、priority(5B)，暂不支持 padding（保持简单）
//  如需 padding，后面可扩展（在首帧 payload 前插 1B padlen + pad bytes）。

// 无 PRIORITY 版本（与你现有调用保持一致）

///|
pub fn build_headers_frames(
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
pub fn build_data_frames(
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
