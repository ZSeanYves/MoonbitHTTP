// http1/parser.mbt — HTTP/1.1 请求解析器
// 请求方法：GET、POST 等
enum Method {
  GET
  POST
  PUT
  DELETE
  HEAD
  OPTIONS
  PATCH
  TRACE
  CONNECT
  Other(String) // 支持扩展方法
}

// 请求行结构：方法、目标、版本
pub struct RequestLine {
  http_method : Method
  target : String
  version : String
}

pub fn parse_request_line(cur : @tsp.BufCursor) -> Result[RequestLine, String] {
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
  let method_str = match
    (try? @buf.utf8_bytes_to_string(Bytes::from_array(parts[0]))) {
    Ok(s) => s
    Err(_) => return Err("Failed to decode method as UTF-8".to_string())
  }
  let method1 = match method_str {
    "GET" => Method::GET
    "POST" => Method::POST
    "PUT" => Method::PUT
    "DELETE" => Method::DELETE
    "HEAD" => Method::HEAD
    "OPTIONS" => Method::OPTIONS
    "PATCH" => Method::PATCH
    "TRACE" => Method::TRACE
    "CONNECT" => Method::CONNECT
    _ => Method::Other(method_str) //  用已解码的字符串
  }

  // 2) 目标（/index.html 等）
  let target = match
    (try? @buf.utf8_bytes_to_string(Bytes::from_array(parts[1]))) {
    Ok(s) => s
    Err(_) => return Err("Failed to decode target as UTF-8".to_string())
  }

  // 3) 版本（HTTP/1.1）
  let version = match
    (try? @buf.utf8_bytes_to_string(Bytes::from_array(parts[2]))) {
    Ok(s) => s
    Err(_) => return Err("Failed to decode version as UTF-8".to_string())
  }
  Ok({ http_method: method1, target, version })
}



impl Show for Method with to_string(self : Method) -> String {
  match self {
    Method::GET => "GET"
    Method::POST => "POST"
    Method::PUT => "PUT"
    Method::DELETE => "DELETE"
    Method::HEAD => "HEAD"
    Method::OPTIONS => "OPTIONS"
    Method::PATCH => "PATCH"
    Method::TRACE => "TRACE"
    Method::CONNECT => "CONNECT"
    Method::Other(s) => s // For custom methods
  }
}


impl Eq for Method with op_equal(self, other) {
  match (self, other) {
    (Method::GET, Method::GET) => true
    (Method::POST, Method::POST) => true
    (Method::PUT, Method::PUT) => true
    (Method::DELETE, Method::DELETE) => true
    (Method::HEAD, Method::HEAD) => true
    (Method::OPTIONS, Method::OPTIONS) => true
    (Method::PATCH, Method::PATCH) => true
    (Method::TRACE, Method::TRACE) => true
    (Method::CONNECT, Method::CONNECT) => true
    (Method::Other(s1), Method::Other(s2)) => s1 == s2
    _ => false
  }
}


impl Show for Method with output(self, logger) {
  match self {
    Method::GET => logger.write_object("GET")
    Method::POST => logger.write_object("POST")
    Method::PUT => logger.write_object("PUT")
    Method::DELETE => logger.write_object("DELETE")
    Method::HEAD => logger.write_object("HEAD")
    Method::OPTIONS => logger.write_object("OPTIONS")
    Method::PATCH => logger.write_object("PATCH")
    Method::TRACE => logger.write_object("TRACE")
    Method::CONNECT => logger.write_object("CONNECT")
    Method::Other(s) => logger.write_object(s)
  }
}


// 测试：请求行解析
test "http1: parse request line (GET)" {
  let cur = @tsp.buf_new()
  cur.buf_push(
    @buf.string_to_utf8_bytes("GET /index.html HTTP/1.1\r\n").to_array(),
  )
  let result = parse_request_line(cur)
  match result {
    Ok(req_line) => {
      assert_eq(req_line.http_method, Method::GET)
      assert_eq(req_line.target, "/index.html")
      assert_eq(req_line.version, "HTTP/1.1")
    }
    Err(_) => {
      let a = true
      assert_eq(a, false)
    }
  }
}

test "http1: parse request line (Other method)" {
  let cur = @tsp.buf_new()
  cur.buf_push(@buf.string_to_utf8_bytes("FOO /bar HTTP/1.1\r\n").to_array())
  let result = parse_request_line(cur)
  match result {
    Ok(req_line) => {
      assert_eq(req_line.http_method, Method::Other("FOO".to_string()))
      assert_eq(req_line.target, "/bar")
      assert_eq(req_line.version, "HTTP/1.1")
    }
    Err(_) => {
      let b = true
      assert_eq(b, false)
    }
  }
}

