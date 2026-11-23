///|
/// Bind a TLS listener that serves HTTP/2 or HTTP/1.1 according to ALPN.
/// A client without ALPN can use HTTP/1.1 when the server enables it.
pub async fn[
  P : @transport.NetworkPolicy,
  T : @transport.TlsProvider,
  B : @body.Body,
] NativeTcpListener::bind_http_tls(
  endpoint : @types.Endpoint,
  policy : P,
  provider : T,
  tls : @transport.TlsOptions,
  handler : async (@types.Request[@body.BodyStream]) -> @types.Response[B],
  config~ : @service.ServerConfig = @service.ServerConfig::defaults(),
  handshake_timeout_ms~ : Int32 = 10000,
  shutdown_timeout_ms~ : Int32 = 1000,
  dual_stack~ : Bool = true,
  reuse_addr~ : Bool = true,
) -> Result[NativeTcpListener, @server_api.ServerError] {
  if config.validate() is Err(_) {
    return Err(InvalidConfig("invalid HTTP service configuration"))
  }
  let alpn = tls.alpn.copy()
  if alpn.any(name => name != "h2" && name != "http/1.1") {
    return Err(InvalidConfig("HTTP listener supports h2 and http/1.1 ALPN"))
  }
  let allow_http1 = alpn.contains("http/1.1")
  let allow_h2 = alpn.contains("h2")
  let shutdown = @service.ServerShutdown::new()
  NativeTcpListener::bind_tls(
    endpoint,
    policy,
    provider,
    { ..tls, alpn, },
    async fn(connection) {
      let io = @service.StreamIo::new(connection.transport)
      match connection.alpn() {
        Some("h2") if allow_h2 =>
          @service.serve_http2_connection(
            io,
            io,
            handler,
            config~,
            shutdown=Some(shutdown),
            finish_transport=async fn() {
              connection.finish().unwrap_or_error()
            },
          )
        Some("http/1.1") | None if allow_http1 =>
          @service.serve_http1_connection(io, io, handler, config~)
        _ =>
          return Err(
            @transport.TlsError::HandshakeFailed(
              "no configured HTTP protocol was negotiated",
            ),
          )
      }
      Ok(())
    },
    handshake_timeout_ms~,
    shutdown_timeout_ms~,
    dual_stack~,
    reuse_addr~,
  ).map(listener => {
    listener.shutdown = Some(shutdown)
    listener
  })
}
