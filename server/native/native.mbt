///|
/// Native TCP listener adapter. The server supervisor and protocol drivers only
/// see the capability-bound `Listener` and `StreamConnection` contracts.
pub struct NativeTcpListener {
  server : @socket.TcpServer
  bind_endpoint : @transport.Endpoint
  handler : async (@transport.StreamConnection) -> Result[Unit, Error]
  mut closed : Bool
}

///|
fn listener_address(
  endpoint : @transport.Endpoint,
) -> Result[@socket.Addr, @server.ServerError] {
  guard endpoint.scheme() == "tcp" else {
    return Err(InvalidConfig("native TCP listener requires tcp scheme"))
  }
  guard @transport.IpAddress::parse(endpoint.host()) is Ok(_) else {
    return Err(
      InvalidConfig("native TCP listener requires a numeric IP bind address"),
    )
  }
  let address = @socket.Addr::parse(endpoint.authority()) catch {
    _ => return Err(InvalidConfig("invalid native TCP listener address"))
  }
  Ok(address)
}

///|
pub async fn NativeTcpListener::bind(
  endpoint : @transport.Endpoint,
  handler : async (@transport.StreamConnection) -> Result[Unit, Error],
  dual_stack? : Bool = true,
  reuse_addr? : Bool = true,
) -> Result[NativeTcpListener, @server.ServerError] {
  // Give cancellation a scheduling point before allocating the host listener.
  @async.pause()
  let address = match listener_address(endpoint) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let server = @socket.TcpServer(address, dual_stack~, reuse_addr~) catch {
    _ => return Err(AcceptFailed("native TCP listener bind failed"))
  }
  Ok({ server, bind_endpoint: endpoint, handler, closed: false, })
}

///|
fn peer_endpoint(
  fallback : @transport.Endpoint,
  peer : @socket.Addr,
) -> @transport.Endpoint {
  let host = if !peer.is_ipv6() {
    let value = peer.ip()
    "\{value >> 24}.\{(value >> 16) & 255}.\{(value >> 8) & 255}.\{value & 255}"
  } else {
    let rendered = peer.to_string()
    guard rendered.has_prefix("[") else { return fallback }
    guard rendered.find("]") is Some(close) else { return fallback }
    rendered[1:close].to_owned()
  }
  match @transport.Endpoint::new("tcp", host, peer.port()) {
    Ok(endpoint) => endpoint
    Err(_) => fallback
  }
}

///|
pub impl @server.Listener for NativeTcpListener with fn accept(self) {
  if self.closed {
    return Ok(None)
  }
  let (tcp, peer) = self.server.accept() catch {
    _ =>
      return if self.closed {
        Ok(None)
      } else {
        Err(AcceptFailed("native TCP accept failed"))
      }
  }
  let endpoint = peer_endpoint(self.bind_endpoint, peer)
  let connection = @transport.StreamConnection::new(
    endpoint,
    async fn(max_bytes) {
      let bytes = tcp.read_some(max_len=max_bytes) catch {
        _ => return Err(Failed(Receive, "native TCP read failed"))
      }
      Ok(bytes)
    },
    async fn(bytes) {
      tcp.write(bytes) catch {
        _ => return Err(Failed(Send, "native TCP write failed"))
      }
      Ok(())
    },
    fn() { tcp.close() },
  )
  let handler = self.handler
  Ok(
    Some(
      @server.AcceptedConnection::new(async fn() { handler(connection) }, fn() {
        connection.close()
      }),
    ),
  )
}

///|
pub impl @server.Listener for NativeTcpListener with fn close(self) {
  if !self.closed {
    self.closed = true
    self.server.close()
  }
}
