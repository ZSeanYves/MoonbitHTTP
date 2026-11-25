///|
/// Run a bounded HTTP/2 pool over native TCP. HTTPS requires negotiated h2.
pub async fn[
  R : @transport.NameResolver,
  P : @transport.NetworkPolicy,
  K : @transport.Clock,
  T : @transport.TlsProvider,
  X,
] with_http2_pool(
  resolver : R,
  policy : P,
  clock : K,
  tls_provider : T,
  run : async (@client_api.Http2Client) -> X,
  options~ : @client_api.Http2PoolOptions = @client_api.Http2PoolOptions::defaults(),
) -> X {
  @client_api.with_http2_pool(
    @transport_native.TcpConnector::new(),
    resolver,
    tls_provider,
    policy,
    clock,
    run,
    options~,
  )
}
