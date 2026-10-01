///|
pub struct Endpoint {
  scheme : String
  host : String
  port : Int
} derive(Eq, Debug, Compare, Hash)

///|
pub(all) suberror EndpointError {
  InvalidScheme
  InvalidHost
  InvalidPort
} derive(Eq, Debug)

///|
fn endpoint_valid_host(value : String) -> Bool {
  let bytes = @utf8.encode(value)
  guard !bytes.is_empty() else { return false }
  // A host passed to this capability is already split from its port.  A colon
  // is therefore valid only as part of an IPv6 literal; accepting
  // `example.test:443` here would make policy and connector authorities
  // disagree about the destination.
  if value.contains(":") {
    return uri_valid_ipv6(bytes)
  }
  validate_reg_name(bytes) is Ok(_)
}

///|
pub fn Endpoint::new(
  scheme : String,
  host : String,
  port : Int,
) -> Result[Endpoint, EndpointError] {
  guard valid_scheme(@utf8.encode(scheme)) else { return Err(InvalidScheme) }
  let normalized_host = if host.has_prefix("[") {
    if !host.has_suffix("]") || host.length() <= 2 {
      return Err(InvalidHost)
    }
    host[1:host.length() - 1].to_owned()
  } else {
    host
  }
  if host.has_prefix("[") && !uri_valid_ipv6(@utf8.encode(normalized_host)) {
    return Err(InvalidHost)
  }
  guard endpoint_valid_host(normalized_host) else { return Err(InvalidHost) }
  guard port > 0 && port <= 65535 else { return Err(InvalidPort) }
  Ok({
    scheme: ascii_lower(@utf8.encode(scheme)),
    host: ascii_lower(@utf8.encode(normalized_host)),
    port,
  })
}

///|
pub fn Endpoint::scheme(self : Endpoint) -> String {
  self.scheme
}

///|
pub fn Endpoint::host(self : Endpoint) -> String {
  self.host
}

///|
pub fn Endpoint::port(self : Endpoint) -> Int {
  self.port
}

///|
pub fn Endpoint::authority(self : Endpoint) -> String {
  let host = self.host
  let rendered = if host.contains(":") && !host.has_prefix("[") {
    "[" + host + "]"
  } else {
    host
  }
  rendered + ":" + self.port.to_string()
}
