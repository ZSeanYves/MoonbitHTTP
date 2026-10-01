///|
fn numeric_socket_addr(endpoint : @types.Endpoint) -> @socket.Addr? {
  guard @types.IpAddress::parse(endpoint.host()) is Ok(_) else { return None }
  Some(@socket.Addr::parse(endpoint.authority()) catch { _ => return None })
}

///|
fn ip_from_socket_addr(address : @socket.Addr) -> @types.IpAddress? {
  if !address.is_ipv6() {
    let value = address.ip()
    let literal = "\{value >> 24}.\{(value >> 16) & 255}.\{(value >> 8) & 255}.\{value & 255}"
    return match @types.IpAddress::parse(literal) {
      Ok(address) => Some(address)
      Err(_) => None
    }
  }
  let rendered = address.to_string()
  guard rendered.has_prefix("[") else { return None }
  guard rendered.find("]") is Some(close) else { return None }
  let literal = rendered[1:close].to_owned()
  // Scoped IPv6 literals cannot currently be represented by IpAddress.
  guard !literal.contains("%") else { return None }
  match @types.IpAddress::parse(literal) {
    Ok(address) => Some(address)
    Err(_) => None
  }
}
