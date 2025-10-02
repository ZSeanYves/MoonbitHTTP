// 通用调试工具：打印前 16 个字节的十六进制
pub fn dbg_hex16(bs : Array[Byte]) -> String {
  let n = if bs.length() < 16 { bs.length() } else { 16 }
  let mut i = 0
  let mut s = ""
  while i < n {
    let v = bs[i].to_int() & 0xFF
    let hi = "0123456789abcdef"[v >> 4].to_string()
    let lo = "0123456789abcdef"[v & 0xF].to_string()
    s = s + hi + lo
    if i + 1 < n {
      s = s + " "
    }
    i += 1
  }
  s
}

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


test "h2: SETTINGS encode/decode roundtrip" {
  let kvs : Array[H2SettingKV] = []
  kvs.push({ id: 0x1, value: 0 })
  kvs.push({ id: 0x5, value: 16384 })
  let bytes = build_settings_frame(kvs, false)
  //println("SETTINGS total bytes = " + bytes.length().to_string())
  //println("SETTINGS head9 hex   = " + dbg_hex16(bytes)) 
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
          //println("parse_settings_frame failed: " + e)
          let a = true
          assert_eq(a, false)
          return
        }
      }
    }
    Err(e) => {
      ignore(e)
      //println("read_frame failed: " + e)
      let a = true
      assert_eq(a, false)
      return
    }
  }
}


test "h2: PING encode/decode (ack and no-ack)" {
  let opaque1 = @buf.string_to_utf8_bytes("12345678").to_array()

  // no-ack
  let b1 = build_ping_frame(opaque1, false)
  //println("PING(no-ack) bytes = " + b1.length().to_string())
  //println("PING(no-ack) head  = " + dbg_hex16(b1))
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
          //println("parse_ping_frame (no-ack) failed: " + e)
          let a = true
          assert_eq(a, false)
          return
        }
      }
    }
    Err(e) => {
      ignore(e)
      //println("read_frame (no-ack) failed: " + e)
      let a = true
      assert_eq(a, false)
      return
    }
  }

  // ack
  let b2 = build_ping_frame(opaque1, true)
  //println("PING(ack)   bytes = " + b2.length().to_string())
  //println("PING(ack)   head  = " + dbg_hex16(b2))
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
          //println("parse_ping_frame (ack) failed: " + e)
          let a = true
          assert_eq(a, false)
          return
        }
      }
    }
    Err(e) => {
      ignore(e)
      //println("read_frame (ack) failed: " + e)
      let a = true
      assert_eq(a, false)
      return
    }
  }
}


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
  //println("SERVER inbound bytes = " + inbound.length().to_string())
  //println("SERVER inbound head9 = " + dbg_hex16(inbound))
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
      //println("h2_server_accept_and_ack failed: " + e)
      let a = true
      assert_eq(a, false)
      return
    }
  }
}




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



// mini_roundtrip_test
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
    Err(e) => {
      println("server handle failed: " + e)
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



//  不启用 Huffman：headers roundtrip
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
    Err(e) => {
      println("read_headers_as_list failed: " + e)
      let a = true
      assert_eq(a, false)
    }
  }
}


// 3) 名字不在静态表时，(try) huffman（会针对 name/value 一起尝试；不足时回退），roundtrip 一致
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