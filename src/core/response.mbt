///|
pub(all) struct Status {
  code : Int
  reason : String // 例如 "OK"、"Not Found"
}

// 响应状态码（常用子集，按 RFC 7231/9110 常见值补全）

///|
pub(all) enum StatusCode {
  // 1xx Informational
  Continue = 100
  SwitchingProtocols = 101
  Processing = 102 // RFC 2518
  EarlyHints = 103 // RFC 8297

  // 2xx Success
  OK = 200
  Created = 201
  Accepted = 202
  NoContent = 204
  PartialContent = 206

  // 3xx Redirection
  MultipleChoices = 300
  MovedPermanently = 301
  Found = 302
  SeeOther = 303
  NotModified = 304
  TemporaryRedirect = 307
  PermanentRedirect = 308

  // 4xx Client Error
  BadRequest = 400
  Unauthorized = 401
  Forbidden = 403
  NotFound = 404
  MethodNotAllowed = 405
  RequestTimeout = 408
  LengthRequired = 411
  PayloadTooLarge = 413 // RFC 7231: "Payload Too Large"（原 413 Request Entity Too Large）
  URITooLong = 414
  UnsupportedMediaType = 415
  ExpectationFailed = 417
  MisdirectedRequest = 421 // RFC 7540
  UnprocessableContent = 422 // RFC 9110（原 422 Unprocessable Entity）
  UpgradeRequired = 426
  TooManyRequests = 429
  RequestHeaderFieldsTooLarge = 431

  // 5xx Server Error
  InternalServerError = 500
  NotImplemented = 501
  BadGateway = 502
  ServiceUnavailable = 503
  GatewayTimeout = 504
  HTTPVersionNotSupported = 505
}

// 状态行（解析/编码用）

///|
pub(all) struct StatusLine {
  version : String
  code : Int
  reason : String
}

///|
pub(all) struct Response {
  status : Status
  headers : Map[String, String]
  body : Body
}

///|
pub(all) struct Limits {
  max_headers : Int
  max_line : Int
  read_win : Int
  max_body : Int
}

// 便捷构造

///|
pub fn status(code : Int, reason : String) -> Status {
  { code, reason }
}

///|
pub fn resp_empty(
  code : Int,
  reason : String,
  headers : Map[String, String],
) -> Response {
  { status: status(code, reason), headers, body: Body::Empty }
}

///|
pub fn resp_bytes(
  code : Int,
  reason : String,
  headers : Map[String, String],
  body : Array[Byte],
) -> Response {
  { status: status(code, reason), headers, body: Body::Bytes(body) }
}

// —— 小工具：是否无消息体（读/写端可共用） ——

///|
pub fn status_no_body(code : Int) -> Bool {
  (code >= 100 && code < 200) || code == 204 || code == 304
}

// —— 小工具：常见状态码的默认 reason phrase ——
// 未覆盖的返回 "Unknown"（编码时建议保留你传入的 reason）

///|
pub fn default_reason(code : Int) -> String {
  match code {
    // 1xx
    100 => "Continue"
    101 => "Switching Protocols"
    102 => "Processing"
    103 => "Early Hints"
    // 2xx
    200 => "OK"
    201 => "Created"
    202 => "Accepted"
    204 => "No Content"
    206 => "Partial Content"
    // 3xx
    300 => "Multiple Choices"
    301 => "Moved Permanently"
    302 => "Found"
    303 => "See Other"
    304 => "Not Modified"
    307 => "Temporary Redirect"
    308 => "Permanent Redirect"
    // 4xx
    400 => "Bad Request"
    401 => "Unauthorized"
    403 => "Forbidden"
    404 => "Not Found"
    405 => "Method Not Allowed"
    408 => "Request Timeout"
    411 => "Length Required"
    413 => "Payload Too Large"
    414 => "URI Too Long"
    415 => "Unsupported Media Type"
    417 => "Expectation Failed"
    421 => "Misdirected Request"
    422 => "Unprocessable Content"
    426 => "Upgrade Required"
    429 => "Too Many Requests"
    431 => "Request Header Fields Too Large"
    // 5xx
    500 => "Internal Server Error"
    501 => "Not Implemented"
    502 => "Bad Gateway"
    503 => "Service Unavailable"
    504 => "Gateway Timeout"
    505 => "HTTP Version Not Supported"
    // fallback
    _ => "Unknown"
  }
}

// —— 便捷构造：从 Int 或 StatusCode 构造 Status ——
// 如果 reason 传空串，可以用 default_reason 补全（按需使用）

///|
pub fn make_status(code : Int, reason : String) -> Status {
  let r = if reason.length() == 0 { default_reason(code) } else { reason }
  { code, reason: r }
}

// 把枚举值映射到整型

///|
pub fn status_code_value(sc : StatusCode) -> Int {
  match sc {
    // 1xx
    StatusCode::Continue => 100
    StatusCode::SwitchingProtocols => 101
    StatusCode::Processing => 102
    StatusCode::EarlyHints => 103
    // 2xx
    StatusCode::OK => 200
    StatusCode::Created => 201
    StatusCode::Accepted => 202
    StatusCode::NoContent => 204
    StatusCode::PartialContent => 206
    // 3xx
    StatusCode::MultipleChoices => 300
    StatusCode::MovedPermanently => 301
    StatusCode::Found => 302
    StatusCode::SeeOther => 303
    StatusCode::NotModified => 304
    StatusCode::TemporaryRedirect => 307
    StatusCode::PermanentRedirect => 308
    // 4xx
    StatusCode::BadRequest => 400
    StatusCode::Unauthorized => 401
    StatusCode::Forbidden => 403
    StatusCode::NotFound => 404
    StatusCode::MethodNotAllowed => 405
    StatusCode::RequestTimeout => 408
    StatusCode::LengthRequired => 411
    StatusCode::PayloadTooLarge => 413
    StatusCode::URITooLong => 414
    StatusCode::UnsupportedMediaType => 415
    StatusCode::ExpectationFailed => 417
    StatusCode::MisdirectedRequest => 421
    StatusCode::UnprocessableContent => 422
    StatusCode::UpgradeRequired => 426
    StatusCode::TooManyRequests => 429
    StatusCode::RequestHeaderFieldsTooLarge => 431
    // 5xx
    StatusCode::InternalServerError => 500
    StatusCode::NotImplemented => 501
    StatusCode::BadGateway => 502
    StatusCode::ServiceUnavailable => 503
    StatusCode::GatewayTimeout => 504
    StatusCode::HTTPVersionNotSupported => 505
  }
}

///|
pub fn make_status_from(code : StatusCode) -> Status {
  let c = status_code_value(code)
  { code: c, reason: default_reason(c) }
}
