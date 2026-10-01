///|
/// Construct the bounded HTTP/1 client with an explicit network policy and
/// native TCP plus explicitly supplied DNS, TLS, and clock capabilities. Policy checks cover
/// DNS, numeric connects, redirects, and proxy CONNECT. HTTP/1.1 is the only
/// ALPN offered by this facade.
pub fn[
  R : @transport.NameResolver,
  P : @transport.NetworkPolicy,
  K : @transport.Clock,
  T : @transport.TlsProvider,
] new_http1_client(
  resolver : R,
  policy : P,
  clock : K,
  tls_provider : T,
  options? : @client_api.RequestOptions = @client_api.RequestOptions::defaults(),
  proxy? : @client_api.ProxyConfig = @client_api.ProxyConfig::direct(),
  origin_tls? : @transport.TlsOptions = {
    ..@transport.TlsOptions::defaults(),
    alpn: ["http/1.1"],
  },
  proxy_tls? : @transport.TlsOptions = {
    ..@transport.TlsOptions::defaults(),
    alpn: ["http/1.1"],
  },
  content_decoding? : Bool = false,
  content_coding_limits? : @content_coding.ContentCodingLimits = @content_coding.ContentCodingLimits::defaults(),
  cache_enabled? : Bool = false,
) -> Result[@client_api.Http1Client, @client_api.ClientError] {
  @client_api.Http1Client::from_capabilities(
    @transport_native.TcpConnector::new(),
    resolver,
    tls_provider,
    policy,
    clock,
    options~,
    proxy~,
    origin_tls~,
    proxy_tls~,
    content_decoding~,
    content_coding_limits~,
    cache_enabled~,
  )
}
