///|
/// Native TCP listener adapter. The server supervisor and protocol drivers only
/// see the capability-bound `Listener` and `StreamConnection` contracts.
pub struct NativeTcpListener {
  server : @socket.TcpServer
  bind_endpoint : @types.Endpoint
  handler : async (@transport.StreamConnection) -> Result[Unit, Error]
  authorize_peer : (@types.Endpoint) -> Result[Unit, @transport.PolicyError]
  mut closed : Bool
}

///|
fn listener_address(
  endpoint : @types.Endpoint,
) -> Result[@socket.Addr, @server_api.ServerError] {
  guard endpoint.scheme() == "tcp" else {
    return Err(InvalidConfig("native TCP listener requires tcp scheme"))
  }
  guard @types.IpAddress::parse(endpoint.host()) is Ok(_) else {
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
pub async fn[P : @transport.NetworkPolicy] NativeTcpListener::bind(
  endpoint : @types.Endpoint,
  policy : P,
  handler : async (@transport.StreamConnection) -> Result[Unit, Error],
  dual_stack? : Bool = true,
  reuse_addr? : Bool = true,
) -> Result[NativeTcpListener, @server_api.ServerError] {
  // Give cancellation a scheduling point before allocating the host listener.
  @async.pause()
  let address = match listener_address(endpoint) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match @transport.NetworkPolicy::authorize(policy, endpoint, Listen) {
    Ok(_) => ()
    Err(error) => return Err(Policy(error))
  }
  let server = @socket.TcpServer(address, dual_stack~, reuse_addr~) catch {
    _ => return Err(AcceptFailed("native TCP listener bind failed"))
  }
  Ok({
    server,
    bind_endpoint: endpoint,
    handler,
    authorize_peer: fn(peer) {
      @transport.NetworkPolicy::authorize(policy, peer, Accept)
    },
    closed: false,
  })
}

///|
/// Accept TCP connections under an explicit policy, authenticate them with the
/// supplied TLS provider, and invoke the handler only after a full handshake.
/// The timeout bounds peers that connect without completing TLS.
pub async fn[P : @transport.NetworkPolicy, T : @transport.TlsProvider] NativeTcpListener::bind_tls(
  endpoint : @types.Endpoint,
  policy : P,
  provider : T,
  options : @transport.TlsOptions,
  handler : async (@transport.SecureConnection) -> Result[Unit, Error],
  handshake_timeout_ms? : Int = 10000,
  dual_stack? : Bool = true,
  reuse_addr? : Bool = true,
) -> Result[NativeTcpListener, @server_api.ServerError] {
  if handshake_timeout_ms <= 0 {
    return Err(InvalidConfig("TLS handshake timeout must be positive"))
  }
  match options.validate_server() {
    Err(_) => return Err(InvalidConfig("invalid server TLS options"))
    Ok(_) => ()
  }
  NativeTcpListener::bind(
    endpoint,
    policy,
    async fn(connection) {
      defer connection.close()
      let result = @async.with_timeout(handshake_timeout_ms, async fn() {
        @transport.TlsProvider::server_handshake(provider, connection, options)
      })
      match result {
        Err(error) => Err(error)
        Ok(secure) => {
          defer secure.close()
          handler(secure)
        }
      }
    },
    dual_stack~,
    reuse_addr~,
  )
}

///|
fn peer_endpoint(
  fallback : @types.Endpoint,
  peer : @socket.Addr,
) -> @types.Endpoint {
  let host = if !peer.is_ipv6() {
    let value = peer.ip()
    "\{value >> 24}.\{(value >> 16) & 255}.\{(value >> 8) & 255}.\{value & 255}"
  } else {
    let rendered = peer.to_string()
    guard rendered.has_prefix("[") else { return fallback }
    guard rendered.find("]") is Some(close) else { return fallback }
    rendered[1:close].to_owned()
  }
  match @types.Endpoint::new("tcp", host, peer.port()) {
    Ok(endpoint) => endpoint
    Err(_) => fallback
  }
}

///|
pub impl @server_api.Listener for NativeTcpListener with fn accept(self) {
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
  match (self.authorize_peer)(endpoint) {
    Ok(_) => ()
    Err(error) => {
      tcp.close()
      return Err(Policy(error))
    }
  }
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
      @server_api.AcceptedConnection::new(async fn() { handler(connection) }, fn() {
        connection.close()
      }),
    ),
  )
}

///|
pub impl @server_api.Listener for NativeTcpListener with fn close(self) {
  if !self.closed {
    self.closed = true
    self.server.close()
  }
}
