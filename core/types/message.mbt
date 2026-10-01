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
pub(all) suberror MethodError {
  EmptyMethod
  InvalidMethodToken
  NonCanonicalMethod
} derive(Debug, Eq)

///|
pub fn Method::parse_bytes(raw : BytesView) -> Result[Method, MethodError] {
  if raw.is_empty() {
    return Err(EmptyMethod)
  }
  for byte in raw {
    if !is_token_byte(byte) {
      return Err(InvalidMethodToken)
    }
  }
  let value = @utf8.decode(raw) catch { _ => return Err(InvalidMethodToken) }
  Ok(
    match value {
      "GET" => Get
      "POST" => Post
      "PUT" => Put
      "DELETE" => Delete
      "HEAD" => Head
      "OPTIONS" => Options
      "PATCH" => Patch
      "TRACE" => Trace
      "CONNECT" => Connect
      extension => Extension(extension)
    },
  )
}

///|
pub fn Method::parse(raw : String) -> Result[Method, MethodError] {
  Method::parse_bytes(@utf8.encode(raw))
}

///|
pub fn Method::as_str(self : Method) -> String {
  match self {
    Get => "GET"
    Post => "POST"
    Put => "PUT"
    Delete => "DELETE"
    Head => "HEAD"
    Options => "OPTIONS"
    Patch => "PATCH"
    Trace => "TRACE"
    Connect => "CONNECT"
    Extension(value) => value
  }
}

///|
pub fn Method::validate(self : Method) -> Result[Unit, MethodError] {
  match Method::parse(self.as_str()) {
    Ok(parsed) if parsed == self => Ok(())
    Ok(_) => Err(NonCanonicalMethod)
    Err(error) => Err(error)
  }
}

///|
pub(all) enum Version {
  Http10
  Http11
  Http2
  Http3
} derive(Debug, Eq)

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
