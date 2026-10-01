///|
/// A bound UDP capability that preserves each datagram's source address.
/// Listening and peer traffic require explicit policy authorization. Endpoints
/// must be numeric; hostname resolution belongs to the caller's resolver.
pub struct UdpServerSocket {
  socket : @socket.UdpServer
  scheme : String
  authorize_peer : (@types.Endpoint) -> Result[Unit, @transport.PolicyError]
  max_datagram_size : Int
  mut closed : Bool
}

///|
pub async fn[P : @transport.NetworkPolicy] UdpServerSocket::bind(
  endpoint : @types.Endpoint,
  policy : P,
  max_datagram_size? : Int = 65527,
  dual_stack? : Bool = true,
) -> Result[UdpServerSocket, @transport.TransportError] {
  if max_datagram_size <= 0 || max_datagram_size > 65527 {
    return Err(InvalidDatagramSize)
  }
  match @transport.NetworkPolicy::authorize(policy, endpoint, Listen) {
    Err(error) => return Err(Policy(error))
    Ok(_) => ()
  }
  let local_addr = match numeric_socket_addr(endpoint) {
    Some(value) => value
    None => return Err(Failed(Resolve, "UDP requires a numeric endpoint"))
  }
  let socket = @socket.UdpServer(local_addr, dual_stack~) catch {
    error => return Err(native_transport_error(Connect, error))
  }
  Ok({
    socket,
    scheme: endpoint.scheme(),
    authorize_peer: fn(peer) {
      @transport.NetworkPolicy::authorize(policy, peer, QuicEndpoint)
    },
    max_datagram_size,
    closed: false,
  })
}

///|
pub impl @transport.DatagramSocket for UdpServerSocket with fn send(
  self,
  endpoint,
  payload,
) {
  if self.closed {
    return Err(Closed)
  }
  if payload.length() > self.max_datagram_size {
    return Err(InvalidDatagramSize)
  }
  match (self.authorize_peer)(endpoint) {
    Err(error) => return Err(Policy(error))
    Ok(_) => ()
  }
  let remote = match numeric_socket_addr(endpoint) {
    Some(value) => value
    None => return Err(Failed(Resolve, "UDP requires a numeric endpoint"))
  }
  self.socket.sendto(payload, remote) catch {
    error => return Err(native_transport_error(Send, error))
  }
  Ok(())
}

///|
pub impl @transport.DatagramSocket for UdpServerSocket with fn receive(
  self,
  max_bytes,
) {
  if self.closed {
    return Err(Closed)
  }
  if max_bytes <= 0 || max_bytes > self.max_datagram_size {
    return Err(InvalidDatagramSize)
  }
  // One sentinel byte distinguishes a complete datagram from silent truncation.
  let buffer = FixedArray::make(max_bytes + 1, b'\x00')
  let (count, peer) = self.socket.recvfrom(buffer) catch {
    error => return Err(native_transport_error(Receive, error))
  }
  if count < 0 || count > max_bytes {
    return Err(InvalidDatagramSize)
  }
  let ip = match ip_from_socket_addr(peer) {
    Some(value) => value
    None =>
      return Err(Failed(Receive, "UDP peer address cannot be represented"))
  }
  let endpoint = match
    @types.Endpoint::new(self.scheme, ip.value(), peer.port()) {
    Ok(value) => value
    Err(error) => return Err(InvalidEndpoint(error))
  }
  match (self.authorize_peer)(endpoint) {
    Err(error) => return Err(Policy(error))
    Ok(_) => ()
  }
  Ok(
    @transport.Datagram::new(
      Bytes::from_array(buffer[:count].to_owned()),
      endpoint,
    ),
  )
}

///|
pub impl @transport.DatagramSocket for UdpServerSocket with fn close(self) {
  if !self.closed {
    self.closed = true
    self.socket.close()
  }
}
