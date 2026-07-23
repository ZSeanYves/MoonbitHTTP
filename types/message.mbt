///|
pub(all) enum Method {
  Get
  Post
  Put
  Delete
  Head
  Options
  Patch
  Trace
  Connect
  Extension(String)
} derive(Debug, Eq)

///|
pub(all) enum Version {
  Http10
  Http11
  Http2
} derive(Debug, Eq)

///|
pub(all) struct Uri {
  value : String
} derive(Debug, Eq)

///|
pub(all) suberror UriError {
  InvalidUri(String)
} derive(Debug, Eq)

///|
pub fn Uri::parse(value : String) -> Result[Uri, UriError] {
  if value.length() == 0 {
    return Err(InvalidUri("URI is empty"))
  }
  let bytes = @utf8.encode(value)
  for b in bytes {
    if b <= b' ' || b == b'\x7f' {
      return Err(InvalidUri("URI contains whitespace or control bytes"))
    }
  }
  Ok({ value, })
}

///|
pub(all) struct Request[B] {
  http_method : Method
  uri : Uri
  version : Version
  headers : HeaderMap
  body : B
}

///|
pub(all) struct Response[B] {
  status : Int
  version : Version
  headers : HeaderMap
  body : B
}

///|
pub fn[A, B] Request::map_body(
  self : Request[A],
  transform : (A) -> B,
) -> Request[B] {
  {
    http_method: self.http_method,
    uri: self.uri,
    version: self.version,
    headers: self.headers,
    body: transform(self.body),
  }
}

///|
pub fn[A, B] Response::map_body(
  self : Response[A],
  transform : (A) -> B,
) -> Response[B] {
  {
    status: self.status,
    version: self.version,
    headers: self.headers,
    body: transform(self.body),
  }
}

///|
pub fn status_allows_body(status : Int) -> Bool {
  !(status >= 100 && status < 200) && status != 204 && status != 304
}

///|
pub fn response_allows_body(http_method : Method, status : Int) -> Bool {
  http_method != Head &&
  !(http_method == Connect && status >= 200 && status < 300) &&
  status_allows_body(status)
}

///|
pub(all) struct Limits {
  max_start_line : Int
  max_header_line : Int
  max_header_count : Int
  max_header_bytes : Int
  max_body_bytes : Int
  max_buffer_bytes : Int
}

///|
pub fn Limits::defaults() -> Limits {
  {
    max_start_line: 8192,
    max_header_line: 8192,
    max_header_count: 100,
    max_header_bytes: 64 * 1024,
    max_body_bytes: 16 * 1024 * 1024,
    max_buffer_bytes: 256 * 1024,
  }
}
