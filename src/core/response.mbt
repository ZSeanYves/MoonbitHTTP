pub(all) struct Status {
  code : Int
  reason : String // 例如 "OK"、"Not Found"
}

// 响应状态码
pub(all) enum StatusCode {
  OK = 200
  NotFound = 404
  InternalServerError = 500
}

pub(all) struct StatusLine {
  version : String
  code : Int
  reason : String
}


pub(all) struct Response {
  status : Status
  headers : Map[String, String]
  body : Body
}

pub(all) struct Limits {
  max_headers : Int
  max_line    : Int
  read_win    : Int
  max_body    : Int
}



// 便捷构造
pub fn status(code : Int, reason : String) -> Status {
  { code, reason }
}

pub fn resp_empty(
  code : Int,
  reason : String,
  headers : Map[String, String],
) -> Response {
  { status: status(code, reason), headers, body: Body::Empty }
}

pub fn resp_bytes(
  code : Int,
  reason : String,
  headers : Map[String, String],
  body : Array[Byte],
) -> Response {
  { status: status(code, reason), headers, body: Body::Bytes(body) }
}
