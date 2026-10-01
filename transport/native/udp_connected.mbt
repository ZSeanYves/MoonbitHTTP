///|
/// A UDP capability for one policy-authorized numeric endpoint. Resolve a
/// hostname explicitly before connecting so its address can be checked before
/// any socket is created, then pass this value to the generic datagram driver.
pub struct UdpSocket {
  socket : @socket.UdpClient
  endpoint : @types.Endpoint
  max_datagram_size : Int
  mut closed : Bool
}

///|
pub async fn[P : @transport.NetworkPolicy] UdpSocket::connect(
  endpoint : @types.Endpoint,
  policy : P,
  max_datagram_size? : Int = 65527,
) -> Result[UdpSocket, @transport.TransportError] {
  if max_datagram_size <= 0 || max_datagram_size > 65527 {
    return Err(InvalidDatagramSize)
  }
  match @transport.NetworkPolicy::authorize(policy, endpoint, QuicEndpoint) {
    Ok(_) => ()
    Err(error) => return Err(Policy(error))
  }
  let remote = match numeric_socket_addr(endpoint) {
    Some(value) => value
    None => return Err(Failed(Resolve, "UDP requires a numeric endpoint"))
  }
  // UdpClient takes the remote address and creates its ephemeral local socket.
  // Passing a wildcard local address here would connect to port zero first.
  let udp = @socket.UdpClient::UdpClient(remote) catch {
    error => return Err(native_transport_error(Connect, error))
  }
  Ok({ socket: udp, endpoint, max_datagram_size, closed: false, })
}

///|
pub impl @transport.DatagramSocket for UdpSocket with fn send(
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
pub impl @transport.DatagramSocket for UdpSocket with fn receive(
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
  let (count, _) = self.socket.recvfrom(buffer) catch {
    error => return Err(native_transport_error(Receive, error))
  }
  if count < 0 || count > max_bytes {
    return Err(InvalidDatagramSize)
  }
  let payload = FixedArray::make(count, b'\x00')
  for index in 0..<count {
    payload[index] = buffer[index]
  }
  Ok(
    @transport.Datagram::new(
      payload.unsafe_reinterpret_as_bytes(),
      self.endpoint,
    ),
  )
}

///|
pub impl @transport.DatagramSocket for UdpSocket with fn close(self) {
  if !self.closed {
    self.closed = true
    self.socket.close()
  }
}
