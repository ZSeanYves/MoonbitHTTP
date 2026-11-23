///|
/// Scoped, direct-origin HTTP/2 executor.
pub struct Http2Client {
  priv pool : OriginPool[@service.H2Client]
  priv max_body_bytes : Int32
}

///|
pub(all) struct Http2PoolOptions {
  max_connections : Int32
  session : @service.H2ClientConfig
  tls : @transport.TlsOptions
  connect_options : @transport.ConnectOptions
  resolve_options : @transport.ResolveOptions
  tls_timeout_ms : Int32?
}

///|
pub fn Http2PoolOptions::defaults() -> Http2PoolOptions {
  {
    max_connections: 32,
    session: @service.H2ClientConfig::defaults(),
    tls: @transport.TlsOptions::defaults(),
    connect_options: @transport.ConnectOptions::defaults(),
    resolve_options: @transport.ResolveOptions::defaults(),
    tls_timeout_ms: Some(10000),
  }
}

///|
/// Open a bounded pool with explicit DNS, numeric connection policy, TLS and clock capabilities.
/// HTTPS requires h2 ALPN. Cleartext HTTP uses HTTP/2 prior knowledge.
pub async fn[
  C : @transport.StreamConnector,
  R : @transport.NameResolver,
  T : @transport.TlsProvider,
  P : @transport.NetworkPolicy,
  K : @transport.Clock,
  X,
] with_http2_client(
  connector : C,
  resolver : R,
  tls_provider : T,
  policy : P,
  clock : K,
  run : async (Http2Client) -> X,
  options~ : Http2PoolOptions = Http2PoolOptions::defaults(),
) -> X {
  let {
    max_connections,
    session: config,
    tls,
    connect_options,
    resolve_options,
    tls_timeout_ms,
  } = options
  if config.validate() is Err(_) {
    raise ClientInvalidOptions("invalid HTTP/2 session configuration")
  }
  if tls.validate_common() is Err(_) {
    raise ClientInvalidOptions("invalid origin TLS options")
  }
  let network = ClientNetwork::from_capabilities(
    connector, resolver, tls_provider, policy, clock,
  )
  let dialer = match
    ClientDialer::new(network, connect_options, resolve_options, tls_timeout_ms) {
    Ok(value) => value
    Err(error) => raise error
  }
  with_origin_pool(
    "HTTP/2",
    max_connections,
    async fn(endpoint, ready, changed) {
      let connection = match dialer.open_direct(endpoint, tls, alpn="h2") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      defer connection.close()
      let io = @service.StreamIo::new(connection)
      @service.with_h2_client_connection(
        io,
        io,
        async fn(client) {
          client.wait_for_settings()
          ready(client)
        },
        config~,
        on_state_change=changed,
      )
      Ok(())
    },
    @service.H2Client::accepts_requests,
    @service.H2Client::is_idle,
    pool => run({ pool, max_body_bytes: config.limits.max_body_bytes, }),
  )
}

///|
pub fn Http2Client::close(self : Http2Client) -> Unit {
  self.pool.close()
}

///|
/// Count opening, usable and draining connections against the same bound.
pub fn Http2Client::connection_count(self : Http2Client) -> Int32 {
  self.pool.sessions.length()
}
