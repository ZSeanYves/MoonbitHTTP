///|
pub struct RequestTarget {
  authority : @types.Authority
  // CONNECT carries only :method and :authority.
  resource : (String, String)?
}

///|
pub fn[B] request_target(
  request : @types.Request[B],
  default_scheme : String,
  fallback~ : @types.Authority? = None,
) -> Result[RequestTarget, String] {
  if request.http_method.validate() is Err(_) ||
    request.uri.validate_request_target(request.http_method) is Err(_) {
    return Err("invalid request target")
  }
  let hosts = request.headers.get_all_string("host")
  let from_host = match hosts[:] {
    [] => None
    [value] => {
      let text = @utf8.decode(value.bytes) catch {
        _ => return Err("invalid Host field")
      }
      match @types.Authority::parse_endpoint(text) {
        Ok(host) => Some(host)
        Err(_) => return Err("invalid Host field")
      }
    }
    _ => return Err("multiple Host fields")
  }
  if request.uri.authority is Some(uri) &&
    from_host is Some(host) &&
    (
      uri.host != host.host ||
      uri.port != host.port ||
      uri.ip_literal != host.ip_literal
    ) {
    return Err("authority mismatch")
  }
  let authority = match (request.uri.authority, from_host, fallback) {
    (Some(a), _, _) | (_, Some(a), _) | (_, _, Some(a)) => a
    _ => return Err("request authority is missing")
  }
  if request.http_method == Connect {
    return Ok({ authority, resource: None, })
  }
  let scheme = request.uri.scheme.unwrap_or(default_scheme).to_lower()
  if (scheme != "http" && scheme != "https") ||
    (request.uri.scheme is Some(value) && value != scheme) {
    return Err("invalid request scheme")
  }
  let path = match request.uri.form {
    AsteriskForm => "*"
    OriginForm | AbsoluteForm =>
      match request.uri.origin_form() {
        Ok(path) => path
        Err(_) => return Err("invalid request path")
      }
    AuthorityForm => return Err("invalid request path")
  }
  Ok({ authority, resource: Some((scheme, path)), })
}

///|
pub fn[A] RequestTarget::pseudo_fields(
  self : RequestTarget,
  meth : @types.Method,
  field : (String, Bytes) -> A,
) -> Array[A] {
  let fields = [field(":method", @utf8.encode(meth.as_str()))]
  if self.resource is Some((scheme, _)) {
    fields.push(field(":scheme", @utf8.encode(scheme)))
  }
  fields.push(field(":authority", @utf8.encode(self.authority.value)))
  if self.resource is Some((_, path)) {
    fields.push(field(":path", @utf8.encode(path)))
  }
  fields
}
