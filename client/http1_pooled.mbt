///|
/// A capability-injected HTTP/1 executor with a bounded real-connection pool.
/// The executor is safe for concurrent async tasks: all pool mutations are
/// synchronous, while the capacity semaphore is the only waiting point.
pub struct Http1PooledRoundTripper {
  priv connect : async (@types.Endpoint, @transport.ConnectOptions) -> Result[
    @transport.StreamConnection,
    @transport.TransportError,
  ]
  priv tls_handshake : async (
    @transport.StreamConnection,
    @transport.TlsOptions,
  ) -> Result[@transport.SecureConnection, @transport.TlsError]
  priv resolve : (async (String, @transport.ResolveOptions) -> Result[
    Array[@types.IpAddress],
    @transport.TransportError,
  ])?
  priv authorize : (@types.Endpoint, @transport.PolicyOperation) -> Result[
    Unit,
    @transport.PolicyError,
  ]
  priv now_millis : () -> Int64
  priv options : RequestOptions
  priv proxy : ProxyConfig
  priv origin_tls : @transport.TlsOptions
  priv proxy_tls : @transport.TlsOptions
  priv origin_tls_identity : String
  priv proxy_tls_identity : String
  priv connect_options : @transport.ConnectOptions
  priv resolve_options : @transport.ResolveOptions
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
  match connect_options.validate() {
    Ok(_) => ()
    Err(_) => return Err(ClientInvalidOptions("invalid connect options"))
  }
  let resolve_options = {
    ..resolve_options,
    timeout_ms: options.timeouts.resolve_ms,
  }
  match resolve_options.validate() {
    Ok(_) => ()
    Err(_) => return Err(ClientInvalidOptions("invalid resolve options"))
  }
  let pool = match ConnectionPool::new(limits=pool_limits) {
    Ok(value) => value
    Err(_) => return Err(ClientInvalidOptions("invalid connection pool limits"))
  }
  Ok({
    connect,
    tls_handshake,
    resolve,
    authorize,
    now_millis,
    options,
    proxy,
    origin_tls,
    proxy_tls,
    origin_tls_identity,
    proxy_tls_identity,
    connect_options,
    resolve_options,
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
  Http1PooledRoundTripper::new(
    async fn(endpoint, connect_options) {
      @transport.StreamConnector::connect(connector, endpoint, connect_options)
    },
    async fn(connection, tls_options) {
      @transport.TlsProvider::client_handshake(
        tls_provider, connection, tls_options,
      )
    },
    resolve=Some(async fn(host, options) {
      @transport.NameResolver::resolve(resolver, host, options)
    }),
    authorize=fn(endpoint, operation) {
      @transport.NetworkPolicy::authorize(policy, endpoint, operation)
    },
    now_millis=fn() { @transport.Clock::monotonic_millis(clock) },
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
