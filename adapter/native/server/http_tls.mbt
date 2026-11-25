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
  config~ : @service.ServerConfig = native_tls_server_config(),
  handshake_timeout_ms~ : Int32 = 10000,
  shutdown_timeout_ms~ : Int32 = 1000,
  dual_stack~ : Bool = true,
  reuse_addr~ : Bool = true,
) -> Result[NativeTcpListener, @server_api.ServerError] {
  NativeTcpListener::bind_http_tls_with_context(
    endpoint,
    policy,
    provider,
    tls,
    (_, request) => handler(request),
    config~,
    handshake_timeout_ms~,
    shutdown_timeout_ms~,
    dual_stack~,
    reuse_addr~,
  )
}

///|
/// Typed request context created by the listener after TLS negotiation.
pub struct RequestContext {
  endpoint : @types.Endpoint
  verified_client_certificate : @transport.VerifiedClientCertificate?
}

///|
/// Pass the verified client identity to every handler on this TLS connection.
pub async fn[
  P : @transport.NetworkPolicy,
  T : @transport.TlsProvider,
  B : @body.Body,
] NativeTcpListener::bind_http_tls_with_context(
  endpoint : @types.Endpoint,
  policy : P,
  provider : T,
  tls : @transport.TlsOptions,
  handle_request : async (RequestContext, @types.Request[@body.BodyStream]) -> @types.Response[
    B,
  ],
  config~ : @service.ServerConfig = native_tls_server_config(),
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
      let context : RequestContext = {
        endpoint: connection.transport.endpoint(),
        verified_client_certificate: connection.verified_client_certificate,
      }
      let handler = async fn(request) { handle_request(context, request) }
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
          @service.serve_http1_connection(
            io,
            io,
            handler,
            config~,
            shutdown=Some(shutdown),
          )
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

///|
/// A TLS record can carry 16 KiB. Let concurrent H2 streams use the
/// configured connection buffer without waiting after the first 65,535 bytes.
fn native_tls_server_config() -> @service.ServerConfig {
  let config = @service.ServerConfig::defaults()
  {
    ..config,
    read_size: 16 * 1024,
    h2_receive_window_bytes: config.limits.max_buffer_bytes,
  }
}
