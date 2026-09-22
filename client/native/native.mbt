///|
/// Construct the bounded HTTP/1 client with the host's native TCP, DNS, TLS,
/// policy, and clock capabilities. HTTP/1.1 is the only ALPN offered by this
/// facade; HTTP/2 callers must use the HTTP/2 service/client packages.
pub fn new_http1_client(
  options? : @client.RequestOptions = @client.RequestOptions::defaults(),
  proxy? : @client.ProxyConfig = @client.ProxyConfig::direct(),
  origin_tls? : @tls.TlsOptions = {
    ..@tls.TlsOptions::defaults(),
    alpn: ["http/1.1"],
  },
  proxy_tls? : @tls.TlsOptions = {
    ..@tls.TlsOptions::defaults(),
    alpn: ["http/1.1"],
  },
  content_decoding? : Bool = false,
  content_coding_limits? : @content_coding.ContentCodingLimits = @content_coding.ContentCodingLimits::defaults(),
  cache_enabled? : Bool = false,
) -> Result[@client.Http1Client, @client.ClientError] {
  new_http1_client_with_policy(
    @transport.AllowAllPolicy::new(),
    options~,
    proxy~,
    origin_tls~,
    proxy_tls~,
    content_decoding~,
    content_coding_limits~,
    cache_enabled~,
  )
}

///|
/// Constructs the Native HTTP/1 client with an explicit network policy.
/// Policy checks cover DNS, numeric connects, redirects, proxy CONNECT, and
/// QUIC endpoint operations where the corresponding capability is used.
pub fn[P : @transport.NetworkPolicy] new_http1_client_with_policy(
  policy : P,
  options? : @client.RequestOptions = @client.RequestOptions::defaults(),
  proxy? : @client.ProxyConfig = @client.ProxyConfig::direct(),
  origin_tls? : @tls.TlsOptions = {
    ..@tls.TlsOptions::defaults(),
    alpn: ["http/1.1"],
  },
  proxy_tls? : @tls.TlsOptions = {
    ..@tls.TlsOptions::defaults(),
    alpn: ["http/1.1"],
  },
  content_decoding? : Bool = false,
  content_coding_limits? : @content_coding.ContentCodingLimits = @content_coding.ContentCodingLimits::defaults(),
  cache_enabled? : Bool = false,
) -> Result[@client.Http1Client, @client.ClientError] {
  @client.Http1Client::from_capabilities(
    @transport_native.TcpConnector::new(),
    @transport_native.NativeResolver::new(),
    @tls_native.NativeTlsProvider::new(),
    policy,
    @transport_native.NativeClock::new(),
    options~,
    proxy~,
    origin_tls~,
    proxy_tls~,
    content_decoding~,
    content_coding_limits~,
    cache_enabled~,
  )
}
