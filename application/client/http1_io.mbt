///|
priv struct Http1PooledSession {
  connection : @transport.StreamConnection
  protocol : @service.ClientConnection[ClientStreamIo, ClientStreamIo]
  proxy_target : @types.Endpoint?
}

///|
fn Http1PooledSession::new(
  connection : @transport.StreamConnection,
  options : RequestOptions,
  proxy_target? : @types.Endpoint? = None,
) -> Result[Http1PooledSession, ClientError] {
  let io = ClientStreamIo::new(connection)
  let protocol = match
    @service.ClientConnection::new(
      io,
      io,
      limits=options.limits,
      read_size=options.limits.max_buffer_bytes.min(8192),
      request_headers_timeout_ms=options.timeouts.request_headers_ms,
      request_body_timeout_ms=options.timeouts.request_body_ms,
      response_headers_timeout_ms=options.timeouts.response_headers_ms,
      response_body_timeout_ms=options.timeouts.response_body_ms,
    ) {
    Ok(value) => value
    Err(_) => {
      connection.close()
      return Err(ClientInvalidOptions("invalid HTTP/1 session configuration"))
    }
  }
  Ok({ connection, protocol, proxy_target, })
}

///|
fn Http1PooledSession::proxy_target(
  self : Http1PooledSession,
) -> @types.Endpoint? {
  self.proxy_target
}

///|
fn Http1PooledSession::close(self : Http1PooledSession) -> Unit {
  self.protocol.close()
  self.connection.close()
}

///|
fn Http1PooledSession::is_reusable(self : Http1PooledSession) -> Bool {
  self.protocol.is_reusable() && !self.connection.is_closed()
}
