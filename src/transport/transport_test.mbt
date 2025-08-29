// transport 的功能测试
// --- 基础：空输入时 read 的行为 ---
test "transport: read() on empty, not closed -> WouldBlock" {
  let io = from_inmemory([])
  let tmp : Array[Byte] = []
  tmp.resize(8, 0)
  match io.read(tmp) {
    Err(IoError::WouldBlock) => ()
    _ => {
      let a = true
      assert_eq(a, false)
    }
  }
}


// --- push_rx + read 基本路径 ---
test "transport: push_rx -> read some bytes" {
  let io = from_inmemory([])
  let a = @buf.string_to_utf8_bytes("GET ").to_array()
  let b = @buf.string_to_utf8_bytes("/").to_array()
  io.push_rx(a)
  io.push_rx(b)
  let buf : Array[Byte] = []
  buf.resize(8, 0)
  let n = match io.read(buf) {
    Ok(n) => n
    _ => {
      let c = true
      assert_eq(c, false)
      0
    }
  }
  let got : Array[Byte] = []
  let mut i = 0
  while i < n {
    got.push(buf[i])
    i += 1
  }
  let d = @buf.string_to_utf8_bytes("GET /").to_array()
  assert_eq(got, d)
  assert_eq(io.rx_len(), 0)
}

// --- read_exact 满足/自旋 ---
// PS：read_exact 里有 WouldBlock 重试逻辑，如后续没有读取到会一直阻塞
test "transport: read_exact n bytes" {
  let io = from_inmemory(@buf.string_to_utf8_bytes("ABCDEF").to_array())
  let bs = match io.read_exact(6) {
    Ok(bs) => bs
    _ => {
      let a = true
      assert_eq(a, false)
      []
    }
  }
  assert_eq(bs, @buf.string_to_utf8_bytes("ABCDEF").to_array())
}



// --- write / write_all + take_tx ---
test "transport: write_all then take_tx" {
  let io = from_inmemory([])
  let resp = @buf.string_to_utf8_bytes("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nHello")
  let _ = io.write_all(resp.to_array())
  let out = io.take_tx()
  assert_eq(out, resp.to_array())
}

// --- flush 是 no-op 但要可调用 ---
test "transport: flush no-op" {
  let io = from_inmemory([])
  let mut ok = true
  match io.flush() {
    Ok(_) => ()
    _ => ok = false
  }
  assert_eq(ok, true)
}

// --- close 后：read 空返回 Eof；write/flush 返回 Closed ---
test "transport: close semantics" {
  let io = from_inmemory([])
  let _ = io.close()

  // read（空 + 已关闭） -> Eof
  let buf : Array[Byte] = []
  buf.resize(4, 0)
  match io.read(buf) {
    Err(IoError::Eof) => ()
    _ => {
      let a = true
      assert_eq(a, false)
    }
  }

  // write -> Closed
  match io.write(@buf.string_to_utf8_bytes("X").to_array()) {
    Err(IoError::Closed) => ()
    _ => {
      let b = true
      assert_eq(b, false)
    }
  }

  // flush -> Closed
  match io.flush() {
    Err(IoError::Closed) => ()
    _ => {
      let c = true
      assert_eq(c, false)
    }
  }
}





// BufCursor 的功能测试

// --- NeedMore：分片到达后再读行 ---
test "bufcursor: read line with fragments (NeedMore -> Ok)" {
  let cur = buf_new()
  cur.buf_push(@buf.string_to_utf8_bytes("GET / HT").to_array())

  match cur.buf_read_line_crlf(8 * 1024) {
    Err(BufError::NeedMore(_)) => ()
    _ => {
      let a = true
      assert_eq(a, false)
    }
  }

  cur.buf_push(@buf.string_to_utf8_bytes("TP/1.1\r\n").to_array())

  let line = match cur.buf_read_line_crlf(8 * 1024) {
    Ok(l) => l
    _ => {
      let b = true
      assert_eq(b, false)
      []
    }
  }
  assert_eq(line, @buf.string_to_utf8_bytes("GET / HTTP/1.1").to_array())
  assert_eq(cur.buf_len(), 0)
  assert_eq(cur.buf_is_empty(), true)
}

// --- LineTooLong：超长行报错 ---
test "bufcursor: line too long" {
  let cur = buf_new()
  // 构造一行 10 个 'A' + CRLF，但 max_len 给 5
  cur.buf_push(@buf.string_to_utf8_bytes("AAAAAAAAAA\r\n").to_array())

  match cur.buf_read_line_crlf(5) {
    Err(BufError::LineTooLong(_)) => ()
    _ => {
      let a = true
      assert_eq(a, false)
    }
  }
}

// --- 连续两行：Back-to-back CRLF ---
test "bufcursor: two lines back-to-back" {
  let cur = buf_new()
  cur.buf_push(@buf.string_to_utf8_bytes("Host: a\r\nUser-Agent: x\r\n").to_array())

  let l1 = match cur.buf_read_line_crlf(8 * 1024) {
    Ok(l) => l
    _ => {
      let a = true
      assert_eq(a, false)
      []
    }
  }
  assert_eq(l1, @buf.string_to_utf8_bytes("Host: a").to_array())

  let l2 = match cur.buf_read_line_crlf(8 * 1024) {
    Ok(l) => l
    _ => {
      let b = true
      assert_eq(b, false)
      []
    }
  }
  assert_eq(l2, @buf.string_to_utf8_bytes("User-Agent: x").to_array())
  assert_eq(cur.buf_is_empty(), true)
}

// --- take/peek/drain 组合语义 ---
test "bufcursor: take/peek/drain semantics" {
  let cur = buf_new()
  cur.buf_push(@buf.string_to_utf8_bytes("abcdef").to_array())

  // peek 前 3 个，不消费
  let p = cur.buf_peek(3)
  assert_eq(p, @buf.string_to_utf8_bytes("abc").to_array())
  assert_eq(cur.buf_len(), 6)

  // take 前 4 个，消费
  let t = cur.buf_take(4)
  assert_eq(t, @buf.string_to_utf8_bytes("abcd").to_array())
  assert_eq(cur.buf_len(), 2)

  // drain 1 个，丢弃
  let d = cur.buf_drain(1)
  assert_eq(d, 1)
  assert_eq(cur.buf_len(), 1)

  // 剩下的应该是 "f"
  let left = cur.buf_take(10)
  assert_eq(left, @buf.string_to_utf8_bytes("f").to_array())
  assert_eq(cur.buf_is_empty(), true)
}
