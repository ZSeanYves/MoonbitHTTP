// http1/headers.mbt — 增量解析 HTTP/1.1 头部
// 判断空白：空格或水平制表符
fn is_ws(b : Byte) -> Bool {
  b == 0x20 || b == 0x09
}

// 在 arr 中查找第一个 b 的位置
fn find_byte(arr : Array[Byte], needle : Byte) -> Int? {
  let mut i = 0
  while i < arr.length() {
    if arr[i] == needle {
      return Some(i)
    }
    i += 1
  }
  None
}

// 左裁剪（空格/制表符）
fn ltrim_ascii(arr : Array[Byte]) -> Array[Byte] {
  let mut i = 0
  while i < arr.length() && is_ws(arr[i]) {
    i += 1
  }
  let out : Array[Byte] = []
  let mut j = i
  while j < arr.length() {
    out.push(arr[j])
    j += 1
  }
  out
}

// 右裁剪（空格/制表符）
fn rtrim_ascii(arr : Array[Byte]) -> Array[Byte] {
  if arr.length() == 0 {
    return arr
  }
  let mut end = arr.length()
  while end > 0 && is_ws(arr[end - 1]) {
    end -= 1
  }
  let out : Array[Byte] = []
  let mut i = 0
  while i < end {
    out.push(arr[i])
    i += 1
  }
  out
}

// UTF-8 字节转字符串（带错误信息）
fn bytes_to_utf8(arr : Array[Byte], ctx : String) -> Result[String, String] {
  match (try? @buf.utf8_bytes_to_string(Bytes::from_array(arr))) {
    Ok(s) => Ok(s)
    Err(_) => Err("invalid utf8 in " + ctx)
  }
}

// 解析头部：读到空行（CRLF）为止
// max_headers: 头部最大数量限制；max_line：单行最大长度（字节）
pub fn parse_headers(
  cur : @tsp.BufCursor,
  max_headers : Int,
  max_line : Int,
) -> Result[Map[String, String], String] {
  let headers : Map[String, String] = Map::new()
  let colon = 0x3A // ':'
  let mut count = 0
  while true {
    // 读一行（不含 CRLF）
    let line = match cur.buf_read_line_crlf(max_line) {
      Ok(bs) => bs
      Err(_) => return Err("read header line failed: ")
    }

    // 空行：头部结束
    if line.length() == 0 {
      break
    }

    // 限制头数量
    count += 1
    if count > max_headers {
      return Err("too many headers")
    }

    // 找到冒号
    let pos = match find_byte(line, colon.to_byte()) {
      Some(p) => p
      None => return Err("malformed header (missing :)")
    }

    // name = [0..pos), value = (pos+1 .. end)
    let mut name : Array[Byte] = []
    let mut i = 0
    while i < pos {
      name.push(line[i])
      i += 1
    }
    name = rtrim_ascii(name) // 名称右裁剪（防止尾部空白）
    let mut value : Array[Byte] = []
    let mut j = pos + 1
    while j < line.length() {
      value.push(line[j])
      j += 1
    }
    value = ltrim_ascii(value) // 值左裁剪
    value = rtrim_ascii(value) // 值右裁剪

    // 转成 String
    let name_s = match bytes_to_utf8(name, "header-name") {
      Ok(s) => s
      Err(e) => return Err(e)
    }
    let value_s = match bytes_to_utf8(value, "header-value") {
      Ok(s) => s
      Err(e) => return Err(e)
    }

    // 覆盖式插入（同名头：以最后一个为准）
    headers.set(name_s, value_s)
  }
  Ok(headers)
}

// http1/headers_test.mbt — 头部解析测试
test "http1: parse headers — two lines then blank" {
  let cur = @tsp.buf_new()
  // 两行头 + 空行结束
  cur.buf_push(@buf.string_to_utf8_bytes("Host: example.com\r\n").to_array())
  cur.buf_push(@buf.string_to_utf8_bytes("User-Agent: curl/8.8\r\n").to_array())
  cur.buf_push(@buf.string_to_utf8_bytes("\r\n").to_array())
  let hs = match parse_headers(cur, 32, 8 * 1024) {
    Ok(h) => h
    Err(_) => {
      let a = true
      assert_eq(a, false)
      Map::new()
    }
  }
  assert_eq(hs.get("Host").unwrap_or(""), "example.com")
  assert_eq(hs.get("User-Agent").unwrap_or(""), "curl/8.8")
}

test "http1: parse headers — trim spaces around value" {
  let cur = @tsp.buf_new()
  cur.buf_push(@buf.string_to_utf8_bytes("X-Token:   abc123   \r\n").to_array())
  cur.buf_push(@buf.string_to_utf8_bytes("\r\n").to_array())
  let hs = parse_headers(cur, 8, 4 * 1024).unwrap()
  assert_eq(hs.get("X-Token").unwrap_or(""), "abc123")
}

test "http1: parse headers — too many headers" {
  let cur = @tsp.buf_new()
  cur.buf_push(@buf.string_to_utf8_bytes("A: 1\r\n").to_array())
  cur.buf_push(@buf.string_to_utf8_bytes("B: 2\r\n").to_array())
  cur.buf_push(@buf.string_to_utf8_bytes("C: 3\r\n").to_array())
  cur.buf_push(@buf.string_to_utf8_bytes("\r\n").to_array())
  match parse_headers(cur, 2, 1024) {
    Err(msg) => assert_eq(msg.strip_prefix("too many headers") != None, true)
    _ => {
      let a = true
      assert_eq(a, false)
    }
  }
}

test "http1: parse headers — malformed (missing colon)" {
  let cur = @tsp.buf_new()
  cur.buf_push(@buf.string_to_utf8_bytes("Bad-Header\r\n").to_array())
  cur.buf_push(@buf.string_to_utf8_bytes("\r\n").to_array())
  match parse_headers(cur, 8, 1024) {
    Err(msg) => assert_eq(msg.strip_prefix("malformed header") != None, true)
    _ => {
      let a = true
      assert_eq(a, false)
    }
  }
}

