pub(all) enum Method {
  GET
  POST
  PUT
  DELETE
  HEAD
  OPTIONS
  PATCH
  TRACE
  CONNECT
  Other(String)
}

pub(all) struct RequestLine {
  http_method : Method
  target      : String
  version     : String
}


pub(all) struct Request {
  line : RequestLine
  headers : Map[String, String]
  body : Body 
}

// 便捷构造
pub fn req_line(
  http_method : Method,
  target : String,
  version : String,
) -> RequestLine {
  { http_method, target, version }
}

pub fn request_new(
  line : RequestLine,
  headers : Map[String, String],
) -> Request {
  { line, headers, body: Body::Empty }
}

// 头部访问（大小写不敏感可后续扩展，如统一存小写）
pub fn header_get(req : Request, key : String) -> String? {
  req.headers.get(key)
}



