///|
pub fn encode_content_length_prefix(content_length : Int) -> String {
  "Content-Length: " + content_length.to_string() + "\r\n\r\n"
}

// 生成 chunked 编码后的字节序列：<hex>\r\n<chunk>\r\n ... 0\r\n\r\n
///|
pub fn encode_chunked_bytes(
  body : Array[Byte],
  chunk_size : Int,
) -> Array[Byte] {
  let mut out : Array[Byte] = []
  let mut i = 0
  while i < body.length() {
    let end = if i + chunk_size <= body.length() {
      i + chunk_size
    } else {
      body.length()
    }
    let size = end - i
    out = @cor.push_ascii(out, @cor._int_to_hex(size) + "\r\n")
    let mut j = i
    while j < end {
      out.push(body[j])
      j += 1
    }
    out = @cor.push_ascii(out, "\r\n")
    i = end
  }
  out = @cor.push_ascii(out, "0\r\n\r\n")
  out
}

// 非分块 = 原样字节；分块 = 上面那个

///|
pub fn encode_body_bytes(
  body : Array[Byte],
  is_chunked : Bool,
  chunk_size? : Int = 1024,
) -> Array[Byte] {
  if is_chunked {
    encode_chunked_bytes(body, chunk_size)
  } else {
    body
  }
}
// 组合成“完整响应字节序列”（状态行 + 头 + 空行/CL + 实体）
// is_chunked=true 时忽略 content_length，写 CRLF + 分块体；否则写 Content-Length + 实体

///|
pub fn encode_response_bytes(
  status : @cor.StatusCode,
  headers : Map[String, String],
  body : Array[Byte],
  is_chunked : Bool,
  chunk_size? : Int = 1024,
  // 如果强制用调用方给的长度（和 body.length() 不同），传入 Some(n)，否则 None 用 body.length()
  content_length_override? : Int? = None,
) -> Array[Byte] {
  let mut out : Array[Byte] = []
  let head = encode_status_line(status) + encode_headers(headers)
  out = @cor.push_ascii(out, head)
  if is_chunked {
    out = @cor.push_ascii(out, "\r\n")
    let chunks = encode_chunked_bytes(body, chunk_size)
    let mut i = 0
    while i < chunks.length() {
      out.push(chunks[i])
      i += 1
    }
  } else {
    let cl = match content_length_override {
      Some(n) => n
      None => body.length()
    }
    out = @cor.push_ascii(out, encode_content_length_prefix(cl))
    let mut i = 0
    while i < body.length() {
      out.push(body[i])
      i += 1
    }
  }
  out
}

// 编码响应状态行（固定 HTTP/1.1；从 StatusCode 通用生成）

///|
pub fn encode_status_line(status : @cor.StatusCode) -> String {
  let code = @cor.status_code_value(status)
  let reason = @cor.default_reason(code)
  "HTTP/1.1 " + code.to_string() + " " + reason + "\r\n"
}

// 编码响应头部（Content-Length, Transfer-Encoding: chunked）

///|
pub fn encode_headers(headers : Map[String, String]) -> String {
  let header_str : Array[String] = []
  let keys = headers.keys()

  // 遍历 keys 并取对应的值
  for key in keys {
    let value = headers.get(key).unwrap_or("") // 获取对应的 value，若没有则默认空字符串
    header_str.push(key + ": " + value)
  }
  return header_str.join("\r\n") + "\r\n"
}

// NOTE: 仅用于文本/测试。二进制场景请使用 encode_response_bytes 或 write_response_once。
// 编码响应体（支持 Content-Length 或 chunked）

///|
pub fn encode_body(body : Array[Byte], content_length : Int) -> String {
  if content_length > 0 {
    // Content-Length 模式
    let a = try @buf.utf8_bytes_to_string(Bytes::from_array(body)) catch {
      _ => return "Failed to decode target as UTF-8"
    } noraise {
      s => s
    }
    return "Content-Length: " + content_length.to_string() + "\r\n\r\n" + a
  } else {
    // Transfer-Encoding: chunked 模式
    let chunks : Array[String] = []
    let mut i = 0
    let chunk_size = 1024
    while i < body.length() {
      let chunk : Array[Byte] = []
      let mut j = i
      while j < i + chunk_size && j < body.length() {
        chunk.push(body[j])
        j += 1
      }
      let chunk_str = try @buf.utf8_bytes_to_string(Bytes::from_array(chunk)) catch {
        _ => return "Failed to decode target as UTF-8"
      } noraise {
        s => s
      }
      chunks.push(
        @cor._int_to_hex(chunk.length()) + "\r\n" + chunk_str + "\r\n",
      )
      i += chunk_size
    }
    chunks.push("0\r\n\r\n")
    return chunks.join("")
  }
}

// 兼容旧签名：content_len==0 + headers["Transfer-Encoding"]=="chunked" => 分块

///|
pub fn encode_response(
  status : @cor.StatusCode,
  headers : Map[String, String],
  body : Array[Byte],
  content_len : Int,
) -> String {
  let is_chunked = content_len == 0 &&
    headers.get("Transfer-Encoding").unwrap_or("") == "chunked"
  let bytes = encode_response_bytes(
    status,
    headers,
    body,
    is_chunked,
    chunk_size=1024,
    content_length_override=if is_chunked { None } else { Some(content_len) },
  )
  try @buf.utf8_bytes_to_string(Bytes::from_array(bytes)) catch {
    _ => {
      let head = encode_status_line(status) + encode_headers(headers)
      if is_chunked {
        head + "\r\n" + "<non-utf8-body-chunked>"
      } else {
        head +
        encode_content_length_prefix(
          if content_len > 0 {
            content_len
          } else {
            body.length()
          },
        ) +
        "<non-utf8-body>"
      }
    }
  } noraise {
    s => s
  }
}

// http1/encoder_test.mbt — 响应编码器测试

///|
test "http1: encode 200 OK response" {
  let body : Array[Byte] = @buf.string_to_utf8_bytes("Hello, world!").to_array()
  let headers : Map[String, String] = Map::new()
  headers.set("Content-Type", "text/plain")
  let response = encode_response(
    @cor.StatusCode::OK,
    headers,
    body,
    body.length(),
  )
  let expected = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\nHello, world!"
  assert_eq(response, expected)
}

///|
test "http1: encode chunked response" {
  let body : Array[Byte] = @buf.string_to_utf8_bytes("Hello, world!").to_array()
  let headers : Map[String, String] = Map::new()
  headers.set("Content-Type", "text/plain")
  headers.set("Transfer-Encoding", "chunked")
  let response = encode_response(@cor.StatusCode::OK, headers, body, 0)
  let expected = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\nd\r\nHello, world!\r\n0\r\n\r\n"
  assert_eq(response, expected)
}

// Test for InternalServerError variant construction

///|
test "http1: encode 500 Internal Server Error response" {
  let body : Array[Byte] = @buf.string_to_utf8_bytes("Server error!").to_array()
  let headers : Map[String, String] = Map::new()
  headers.set("Content-Type", "text/plain")
  let response = encode_response(
    @cor.StatusCode::InternalServerError,
    headers,
    body,
    body.length(),
  )
  let expected = "HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\nServer error!"
  assert_eq(response, expected)
}

// Test for NotFound variant construction 

///|
test "http1: encode 404 Not Found response" {
  let body : Array[Byte] = @buf.string_to_utf8_bytes("Not found!").to_array()
  let headers : Map[String, String] = Map::new()
  headers.set("Content-Type", "text/plain")
  let response = encode_response(
    @cor.StatusCode::NotFound,
    headers,
    body,
    body.length(),
  )
  let expected = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 10\r\n\r\nNot found!"
  assert_eq(response, expected)
}

///|
test "http1: encode_response_bytes fixed-length (binary-safe)" {
  let body : Array[Byte] = [0xde, 0xad, 0xbe, 0xef]
  let headers : Map[String, String] = Map::new()
  headers.set("X-Bin", "yes")
  let bytes = encode_response_bytes(@cor.StatusCode::OK, headers, body, false)
  // 断言：末尾 4 字节就是原始 body
  let n = bytes.length()
  assert_eq(bytes[n - 4], 0xde)
  assert_eq(bytes[n - 3], 0xad)
  assert_eq(bytes[n - 2], 0xbe)
  assert_eq(bytes[n - 1], 0xef)
}

///|
test "http1: encode_response_bytes chunked (hex size lower-case)" {
  let body : Array[Byte] = @buf.string_to_utf8_bytes("Hello, world!").to_array()
  let headers : Map[String, String] = Map::new()
  headers.set("Transfer-Encoding", "chunked")
  let bytes = encode_response_bytes(
    @cor.StatusCode::OK,
    headers,
    body,
    true,
    chunk_size=64,
  )
  // 抽取尾部 "0\r\n\r\n"
  let tail : Array[Byte] = []
  let i0 = bytes.length() - 5
  let mut i = i0
  while i < bytes.length() {
    tail.push(bytes[i])
    i += 1
  }
  let tail_s = (try? @buf.utf8_bytes_to_string(Bytes::from_array(tail))).unwrap_or(
    "",
  )
  assert_eq(tail_s, "0\r\n\r\n")
}
