///|
/// A UDP capability for one policy-authorized numeric unicast endpoint. Resolve a
/// hostname explicitly before connecting so its address can be checked before
/// any socket is created, then pass this value to the generic datagram driver.
pub struct UdpSocket {
  socket : @socket.UdpClient
  endpoint : @types.Endpoint
  max_datagram_size : Int32
  mut closed : Bool
}

///|
fn udp_connected_is_multicast(address : @socket.Addr) -> Bool {
  if address.ip.is_multicast() {
    return true
  }
  // IPv4-mapped IPv6 peers carry the IPv4 address in their final four bytes.
  guard address.ip is Ipv6(bytes, ..) else { return false }
  bytes[:12] == b"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xff\xff" &&
  bytes[12] is (224..<240)
}

///|
pub async fn[P : @transport_api.NetworkPolicy] UdpSocket::connect(
  endpoint : @types.Endpoint,
  policy : P,
  max_datagram_size~ : Int32 = 65527,
) -> Result[UdpSocket, @transport_api.TransportError] {
  if max_datagram_size <= 0 || max_datagram_size > 65527 {
    return Err(InvalidDatagramSize)
  }
  match
    @transport_api.NetworkPolicy::authorize(policy, endpoint, QuicEndpoint) {
    Ok(_) => ()
    Err(error) => return Err(Policy(error))
  }
  let remote = match numeric_socket_addr(endpoint) {
    Some(value) => value
    None => return Err(Failed(Resolve, "UDP requires a numeric endpoint"))
  }
  // Multicast UdpClient sockets accept replies from arbitrary peers. This
  // capability promises one authorized peer and cannot attribute such replies
  // to the configured group address.
  if udp_connected_is_multicast(remote) {
    return Err(Failed(Connect, "connected UDP requires a unicast endpoint"))
  }
  // UdpClient takes the remote address and creates its ephemeral local socket.
  // Passing a wildcard local address here would connect to port zero first.
  let udp = @socket.UdpClient::UdpClient(remote) catch {
    error => return Err(native_transport_error(Connect, error))
  }
  Ok({ socket: udp, endpoint, max_datagram_size, closed: false, })
}

///|
pub impl @transport_api.DatagramSocket for UdpSocket with fn send(
  self,
  endpoint,
  payload,
) {
  if self.closed {
    return Err(Closed)
  }
  if endpoint != self.endpoint {
    return Err(Failed(Send, "connected UDP endpoint cannot change"))
  }
  if payload.length() > self.max_datagram_size {
    return Err(InvalidDatagramSize)
  }
  self.socket.send(payload) catch {
    error => return Err(native_transport_error(Send, error))
  }
  Ok(())
}

///|
pub impl @transport_api.DatagramSocket for UdpSocket with fn receive(
  self,
  max_bytes,
) {
  if self.closed {
    return Err(Closed)
  }
  if max_bytes <= 0 || max_bytes > self.max_datagram_size {
    return Err(InvalidDatagramSize)
  }
  // Detect oversized datagrams instead of accepting a silently truncated one.
  let buffer = FixedArray::make(max_bytes + 1, b'\x00')
  let count = self.socket.recv_into(buffer.mut_view()) catch {
    error => return Err(native_transport_error(Receive, error))
  }
  if count < 0 || count > max_bytes {
    return Err(InvalidDatagramSize)
  }
  Ok(
    @transport_api.Datagram::new(
      buffer.unsafe_reinterpret_as_bytes()[:count].to_owned(),
      self.endpoint,
    ),
  )
}

///|
pub impl @transport_api.DatagramSocket for UdpSocket with fn close(self) {
  if !self.closed {
    self.closed = true
    self.socket.close()
  }
}
