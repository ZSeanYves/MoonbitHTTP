// http1/parser.mbt — HTTP/1.1 请求解析器
// 请求方法：GET、POST 等
///|
fn parse_request_line(
  cur : @tsp.BufCursor,
) -> Result[@cor.RequestLine, String] {
  // 读一整行（不含 CRLF）
  let line = match cur.buf_read_line_crlf(1024) {
    Ok(l) => l
    Err(_) => return Err("Failed to read request line".to_string())
  }

  // 按空格分为 3 段：METHOD, TARGET, VERSION
  let parts = @buf.split_array_bytes(line, 0x20) // 0x20 = ' '
  if parts.length() != 3 {
    return Err("Invalid request line format".to_string())
  }

  // 1) 方法字符串
  let method_str = try @buf.utf8_bytes_to_string(Bytes::from_array(parts[0])) catch {
    _ => return Err("Failed to decode method as UTF-8".to_string())
  } noraise {
    s => s
  }
  let method1 = match method_str {
    "GET" => @cor.Method::GET
    "POST" => @cor.Method::POST
    "PUT" => @cor.Method::PUT
    "DELETE" => @cor.Method::DELETE
    "HEAD" => @cor.Method::HEAD
    "OPTIONS" => @cor.Method::OPTIONS
    "PATCH" => @cor.Method::PATCH
    "TRACE" => @cor.Method::TRACE
    "CONNECT" => @cor.Method::CONNECT
    _ => @cor.Method::Other(method_str) //  用已解码的字符串
  }

  // 2) 目标（/index.html 等）
  let target = try @buf.utf8_bytes_to_string(Bytes::from_array(parts[1])) catch {
    _ => return Err("Failed to decode target as UTF-8".to_string())
  } noraise {
    s => s
  }

  // 3) 版本（HTTP/1.1）
  let version = try @buf.utf8_bytes_to_string(Bytes::from_array(parts[2])) catch {
    _ => return Err("Failed to decode version as UTF-8".to_string())
  } noraise {
    s => s
  }
  Ok({ http_method: method1, target, version })
}
