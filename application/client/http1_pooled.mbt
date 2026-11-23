///|
/// A capability-injected HTTP/1 executor with a bounded real-connection pool.
/// The executor is safe for concurrent async tasks: all pool mutations are
/// synchronous, while the capacity semaphore is the only waiting point.
pub struct Http1PooledRoundTripper {
  priv dialer : ClientDialer
  priv options : RequestOptions
  priv proxy : ProxyConfig
  priv origin_tls : @transport.TlsOptions
  priv proxy_tls : @transport.TlsOptions
  priv origin_tls_identity : String
  priv proxy_tls_identity : String
  priv pool : ConnectionPool
  priv slots : @async.Semaphore
  priv sessions : Map[Int, Http1PooledSession]
  priv mut closed : Bool
}

///|
/// Construct a callback-backed executor. Without `resolve`, only numeric
/// endpoints are accepted; hostname origins and proxies require a resolver.
/// Authorization and monotonic time are always explicit host capabilities.
pub fn Http1PooledRoundTripper::new(
  connect : async (@types.Endpoint, @transport.ConnectOptions) -> Result[
    @transport.StreamConnection,
    @transport.TransportError,
  ],
  tls_handshake : async (@transport.StreamConnection, @transport.TlsOptions) -> Result[
    @transport.SecureConnection,
    @transport.TlsError,
  ],
  authorize~ : (@types.Endpoint, @transport.PolicyOperation) -> Result[
    Unit,
    @transport.PolicyError,
  ],
  now_millis~ : () -> Int64,
  resolve? : (async (String, @transport.ResolveOptions) -> Result[
    Array[@types.IpAddress],
    @transport.TransportError,
  ])? = None,
  options? : RequestOptions = RequestOptions::defaults(),
  proxy? : ProxyConfig = ProxyConfig::direct(),
  origin_tls? : @transport.TlsOptions = http1_tls_defaults(),
  proxy_tls? : @transport.TlsOptions = http1_tls_defaults(),
  origin_tls_identity? : String = "origin-tls",
  proxy_tls_identity? : String = "proxy-tls",
  connect_options? : @transport.ConnectOptions = @transport.ConnectOptions::defaults(),
  resolve_options? : @transport.ResolveOptions = @transport.ResolveOptions::defaults(),
  pool_limits? : PoolLimits = PoolLimits::defaults(),
) -> Result[Http1PooledRoundTripper, ClientError] {
  Http1PooledRoundTripper::from_network(
    { connect, tls_handshake, resolve, authorize, now_millis, },
    options~,
    proxy~,
    origin_tls~,
    proxy_tls~,
    origin_tls_identity~,
    proxy_tls_identity~,
    connect_options~,
    resolve_options~,
    pool_limits~,
  )
}

///|
fn Http1PooledRoundTripper::from_network(
  network : ClientNetwork,
  options~ : RequestOptions,
  proxy~ : ProxyConfig,
  origin_tls~ : @transport.TlsOptions,
  proxy_tls~ : @transport.TlsOptions,
  origin_tls_identity~ : String,
  proxy_tls_identity~ : String,
  connect_options~ : @transport.ConnectOptions,
  resolve_options~ : @transport.ResolveOptions,
  pool_limits~ : PoolLimits,
) -> Result[Http1PooledRoundTripper, ClientError] {
  match options.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match proxy.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match origin_tls.validate_common() {
    Ok(_) => ()
    Err(_) => return Err(ClientInvalidOptions("invalid origin TLS options"))
  }
  match proxy_tls.validate_common() {
    Ok(_) => ()
    Err(_) => return Err(ClientInvalidOptions("invalid proxy TLS options"))
  }
  if origin_tls_identity.is_empty() || proxy_tls_identity.is_empty() {
    return Err(ClientInvalidOptions("TLS pool identities must not be empty"))
  }
  let connect_options = {
    ..connect_options,
    timeout_ms: options.timeouts.connect_ms,
    idle_timeout_ms: options.timeouts.idle_ms,
  }
  let resolve_options = {
    ..resolve_options,
    timeout_ms: options.timeouts.resolve_ms,
  }
  let dialer = match
    ClientDialer::new(
      network,
      connect_options,
      resolve_options,
      options.timeouts.tls_ms,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let pool = match ConnectionPool::new(limits=pool_limits) {
    Ok(value) => value
    Err(_) => return Err(ClientInvalidOptions("invalid connection pool limits"))
  }
  Ok({
    dialer,
    options,
    proxy,
    origin_tls,
    proxy_tls,
    origin_tls_identity,
    proxy_tls_identity,
    pool,
    slots: Semaphore(pool_limits.max_total),
    sessions: Map([]),
    closed: false,
  })
}

///|
/// Creates an executor that resolves hostnames explicitly and rechecks each
/// numeric address against the network policy before opening a socket.
pub fn[
  C : @transport.StreamConnector,
  R : @transport.NameResolver,
  T : @transport.TlsProvider,
  P : @transport.NetworkPolicy,
  K : @transport.Clock,
] Http1PooledRoundTripper::from_capabilities(
  connector : C,
  resolver : R,
  tls_provider : T,
  policy : P,
  clock : K,
  options? : RequestOptions = RequestOptions::defaults(),
  proxy? : ProxyConfig = ProxyConfig::direct(),
  origin_tls? : @transport.TlsOptions = http1_tls_defaults(),
  proxy_tls? : @transport.TlsOptions = http1_tls_defaults(),
  origin_tls_identity? : String = "origin-tls",
  proxy_tls_identity? : String = "proxy-tls",
  connect_options? : @transport.ConnectOptions = @transport.ConnectOptions::defaults(),
  resolve_options? : @transport.ResolveOptions = @transport.ResolveOptions::defaults(),
  pool_limits? : PoolLimits = PoolLimits::defaults(),
) -> Result[Http1PooledRoundTripper, ClientError] {
  Http1PooledRoundTripper::from_network(
    ClientNetwork::from_capabilities(
      connector, resolver, tls_provider, policy, clock,
    ),
    options~,
    proxy~,
    origin_tls~,
    proxy_tls~,
    origin_tls_identity~,
    proxy_tls_identity~,
    connect_options~,
    resolve_options~,
    pool_limits~,
  )
}
