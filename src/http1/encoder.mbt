// http1/encoder.mbt — HTTP 响应编码器
// 响应状态码
pub enum StatusCode {
  OK = 200
  NotFound = 404
  InternalServerError = 500
}



// 编码响应体（支持 Content-Length 或 chunked）
pub fn encode_body(body : Array[Byte], content_length : Int) -> String {
  if content_length > 0 {
    // Content-Length 模式
    let a = match (try? @buf.utf8_bytes_to_string(Bytes::from_array(body))) {
      Ok(s) => s
      Err(_) => return "Failed to decode target as UTF-8"
    }
    return "Content-Length: " + content_length.to_string() + "\r\n\r\n" + a
  } else {
    // Transfer-Encoding: chunked 模式
    let chunks : Array[String] = []
    let mut i = 0
    let chunk_size = 1024 // 每块 1024 字节

    while i < body.length() {
      let chunk : Array[Byte] = []
      let mut j = i
      while j < i + chunk_size && j < body.length() {
        chunk.push(body[j])
        j += 1
      }

      // 将块的内容转为字符串并拼接
      let chunk_str = match (try? @buf.utf8_bytes_to_string(Bytes::from_array(chunk))) {
        Ok(s) => s
        Err(_) => return "Failed to decode target as UTF-8"
      }
      chunks.push(chunk.length().to_string() + "\r\n" + chunk_str + "\r\n")
      i += chunk_size
    }

    // 添加 chunked 结束标志
    chunks.push("0\r\n\r\n")
    return chunks.join("")
  }
}



// 编码响应状态行（HTTP/1.1 200 OK）
pub fn encode_status_line(status : StatusCode) -> String {
  match status {
    StatusCode::OK => "HTTP/1.1 200 OK\r\n"
    StatusCode::NotFound => "HTTP/1.1 404 Not Found\r\n"
    StatusCode::InternalServerError => "HTTP/1.1 500 Internal Server Error\r\n"
  }
}

// 编码响应头部（Content-Length, Transfer-Encoding: chunked）
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


// 编码完整响应（状态行、头部、体）
pub fn encode_response(
  status : StatusCode,
  headers : Map[String, String],
  body : Array[Byte],
  content_length : Int,
) -> String {
  let status_line = encode_status_line(status) // 使用 StatusCode 枚举
  let header_str = encode_headers(headers)
  let body_str = encode_body(body, content_length)
  return status_line + header_str + body_str
}


// http1/encoder_test.mbt — 响应编码器测试


test "http1: encode 200 OK response" {
  let body : Array[Byte] = @buf.string_to_utf8_bytes("Hello, world!").to_array()
  let headers : Map[String, String] = Map::new()
  headers.set("Content-Type", "text/plain")
  let response = encode_response(StatusCode::OK, headers, body, body.length())
  let expected = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\nHello, world!"
  assert_eq(response, expected)
}
/// TODO
///test "http1: encode chunked response" {
///  let body : Array[Byte] = @buf.string_to_utf8_bytes("Hello, world!").to_array()
///  let headers : Map[String, String] = Map::new()
///  headers.set("Content-Type", "text/plain")
///  headers.set("Transfer-Encoding", "chunked")
///  let response = encode_response(StatusCode::OK, headers, body, 0)
///  let expected = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n13\r\nHello, world!\r\n0\r\n\r\n"
///  assert_eq(response, expected)
///}

// Test for InternalServerError variant construction
test "http1: encode 500 Internal Server Error response" {
  let body : Array[Byte] = @buf.string_to_utf8_bytes("Server error!").to_array()
  let headers : Map[String, String] = Map::new()
  headers.set("Content-Type", "text/plain")
  let response = encode_response(
    StatusCode::InternalServerError,
    headers,
    body,
    body.length(),
  )
  let expected = "HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\nServer error!"
  assert_eq(response, expected)
}

// Test for NotFound variant construction 
test "http1: encode 404 Not Found response" {
  let body : Array[Byte] = @buf.string_to_utf8_bytes("Not found!").to_array()
  let headers : Map[String, String] = Map::new()
  headers.set("Content-Type", "text/plain")
  let response = encode_response(
    StatusCode::NotFound,
    headers,
    body,
    body.length(),
  )
  let expected = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 10\r\n\r\nNot found!"
  assert_eq(response, expected)
}