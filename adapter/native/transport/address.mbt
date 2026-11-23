///|
fn numeric_socket_addr(endpoint : @types.Endpoint) -> @socket.Addr? {
  guard @types.IpAddress::parse(endpoint.host()) is Ok(_) else { return None }
  Some(@socket.Addr::parse(endpoint.authority()) catch { _ => return None })
}

///|
fn ip_from_socket_addr(address : @socket.Addr) -> @types.IpAddress? {
  let host = address.ip.to_string()
  let literal = match address.ip {
    Ipv6(_, scope_id=0) => host[1:host.length() - 1].to_owned()
    Ipv6(_, ..) => return None
    Ipv4(_) => host
  }
  match @types.IpAddress::parse(literal) {
    Ok(address) => Some(address)
    Err(_) => None
  }
}
