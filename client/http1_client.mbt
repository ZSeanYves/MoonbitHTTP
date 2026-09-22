///|
fn http1_tls_defaults() -> @tls.TlsOptions {
  { ..@tls.TlsOptions::defaults(), alpn: ["http/1.1"], }
}

///|
/// A directly usable HTTP/1 policy client. It owns both application policy
/// state and the physical connection pool, so cookies, cache entries,
/// credentials, and connections cannot be shared accidentally across clients.
pub struct Http1Client {
  priv policy_client : Client
  priv round_tripper : Http1PooledRoundTripper
  priv wall_clock_seconds : () -> Int64
}

///|
pub fn Http1Client::new(
  policy_client : Client,
  round_tripper : Http1PooledRoundTripper,
  wall_clock_seconds? : () -> Int64 = fn() { 0L },
) -> Http1Client {
  { policy_client, round_tripper, wall_clock_seconds, }
}

///|
/// Builds a production-shaped HTTP/1 client from explicit host capabilities.
/// DNS answers are converted to numeric endpoints and checked by `policy`
/// before `connector` receives them.
pub fn[
  C : @transport.StreamConnector,
  R : @transport.NameResolver,
  T : @tls.TlsProvider,
  P : @transport.NetworkPolicy,
  K : @transport.Clock,
] Http1Client::from_capabilities(
  connector : C,
  resolver : R,
  tls_provider : T,
  policy : P,
  clock : K,
  options? : RequestOptions = RequestOptions::defaults(),
  proxy? : ProxyConfig = ProxyConfig::direct(),
  origin_tls? : @tls.TlsOptions = http1_tls_defaults(),
  proxy_tls? : @tls.TlsOptions = http1_tls_defaults(),
  cookie_jar? : @cookie.CookieJar = @cookie.CookieJar::new().unwrap(),
  cache? : @cache.HttpCache = @cache.HttpCache::new().unwrap(),
  cache_enabled? : Bool = false,
  wait? : async (Int64) -> Unit = client_default_wait,
  origin_tls_identity? : String = "origin-tls",
  proxy_tls_identity? : String = "proxy-tls",
  connect_options? : @transport.ConnectOptions = @transport.ConnectOptions::defaults(),
  resolve_options? : @transport.ResolveOptions = @transport.ResolveOptions::defaults(),
  content_decoding? : Bool = false,
  content_coding_limits? : @content_coding.ContentCodingLimits = @content_coding.ContentCodingLimits::defaults(),
  pool_limits? : PoolLimits = PoolLimits::defaults(),
) -> Result[Http1Client, ClientError] {
  let now_millis = fn() { @transport.Clock::monotonic_millis(clock) }
  let wall_clock_seconds = fn() { @transport.Clock::wall_clock_seconds(clock) }
  let policy_client = match
    Client::new(
      options~,
      proxy~,
      tls=origin_tls,
      cookie_jar~,
      cache~,
      cache_enabled~,
      wait~,
      authorize_redirect=fn(endpoint, operation) {
        @transport.NetworkPolicy::authorize(policy, endpoint, operation)
      },
      now_millis~,
      content_decoding~,
      content_coding_limits~,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let round_tripper = match
    Http1PooledRoundTripper::from_capabilities_with_resolver(
      connector,
      resolver,
      tls_provider,
      policy,
      now_millis~,
      options~,
      proxy~,
      origin_tls~,
      proxy_tls~,
      origin_tls_identity~,
      proxy_tls_identity~,
      connect_options~,
      resolve_options~,
      pool_limits~,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({ policy_client, round_tripper, wall_clock_seconds, })
}

///|
/// Sends one bounded byte-body request using the client's current wall clock.
/// Response aggregation is capped by `RequestOptions.limits.max_body_bytes`.
pub async fn Http1Client::send(
  self : Http1Client,
  request : @types.Request[Bytes],
) -> Result[@types.Response[Bytes], ClientError] {
  self.policy_client.send(
    self.round_tripper,
    request,
    (self.wall_clock_seconds)(),
  )
}

///|
/// Deterministic variant for replay tests and externally managed clocks.
pub async fn Http1Client::send_at(
  self : Http1Client,
  request : @types.Request[Bytes],
  now_seconds : Int64,
) -> Result[@types.Response[Bytes], ClientError] {
  self.policy_client.send(self.round_tripper, request, now_seconds)
}

///|
pub fn Http1Client::cookie_jar(self : Http1Client) -> @cookie.CookieJar {
  self.policy_client.cookie_jar()
}

///|
pub fn Http1Client::cache(self : Http1Client) -> @cache.HttpCache {
  self.policy_client.cache()
}

///|
pub fn Http1Client::connection_count(self : Http1Client) -> Int {
  self.round_tripper.connection_count()
}

///|
pub fn Http1Client::idle_connection_count(self : Http1Client) -> Int {
  self.round_tripper.idle_connection_count()
}

///|
pub fn Http1Client::set_content_decoding(
  self : Http1Client,
  enabled : Bool,
) -> Unit {
  self.policy_client.set_content_decoding(enabled)
}

///|
pub fn Http1Client::content_decoding(self : Http1Client) -> Bool {
  self.policy_client.content_decoding()
}

///|
pub fn Http1Client::content_coding_limits(
  self : Http1Client,
) -> @content_coding.ContentCodingLimits {
  self.policy_client.content_coding_limits()
}

///|
/// Stops new requests and closes all active and idle physical connections.
pub fn Http1Client::close(self : Http1Client) -> Unit {
  self.round_tripper.close()
}
