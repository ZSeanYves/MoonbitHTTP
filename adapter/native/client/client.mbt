///|
/// Use one reusable policy client for the selected protocol within the callback.
pub async fn[P : @transport.NetworkPolicy, X] with_client(
  run : async (@client_api.Client) -> X,
  version~ : @types.Version,
  policy~ : P,
  options~ : @client_api.RequestOptions = @client_api.RequestOptions::defaults(),
  tls? : @transport.TlsOptions,
  proxy~ : @client_api.ProxyConfig = @client_api.ProxyConfig::direct(),
  proxy_tls~ : @transport.TlsOptions = {
    ..@transport.TlsOptions::defaults(),
    alpn: ["http/1.1"],
  },
  max_connections~ : Int32 = 32,
  cache_enabled~ : Bool = false,
  content_decoding~ : Bool = false,
  content_coding_limits~ : @content_coding.ContentCodingLimits = @content_coding.ContentCodingLimits::defaults(),
) -> X {
  if max_connections < 1 {
    raise @client_api.ClientError::ClientInvalidOptions("invalid pool size")
  }
  if version is (Http2 | Http3) && proxy.mode != Direct {
    raise @client_api.ClientError::ClientInvalidOptions("proxy requires HTTP/1")
  }
  let resolver = @transport_native.NativeResolver::new()
  let clock = @transport_native.NativeClock::new()
  let tls_provider = @tls_native.NativeTlsProvider::new()
  let tls = tls.unwrap_or(
    match version {
      Http3 => @transport.TlsOptions::quic_defaults()
      Http2 => { ..@transport.TlsOptions::defaults(), alpn: ["h2"], }
      _ => { ..@transport.TlsOptions::defaults(), alpn: ["http/1.1"], }
    },
  )
  let serve = async fn(exchange) {
    @client_api.with_client(
      run,
      version~,
      exchange~,
      options~,
      proxy~,
      tls~,
      cache_enabled~,
      content_decoding~,
      content_coding_limits~,
      now_millis=() => clock.monotonic_millis(),
      wall_clock_seconds=() => clock.wall_clock_seconds(),
      authorize_redirect=(endpoint, op) => policy.authorize(endpoint, op),
    )
  }
  match version {
    Http10 | Http11 => {
      let limits = @client_api.PoolLimits::defaults()
      let pool = @client_api.Http1PooledRoundTripper::from_capabilities(
        @transport_native.TcpConnector::new(),
        resolver,
        tls_provider,
        policy,
        clock,
        options~,
        proxy~,
        origin_tls=tls,
        proxy_tls~,
        pool_limits={
          max_total: max_connections,
          max_idle: limits.max_idle.min(max_connections),
        },
      ).unwrap_or_error()
      defer pool.close()
      serve(async fn(request) {
        pool
        .execute_body(request)
        .unwrap_or_error()
        .map_body(body => @client_api.IncomingBody::wrap(body))
      })
    }
    Http2 => {
      let defaults = @client_api.Http2PoolOptions::defaults()
      with_http2_pool(
        resolver,
        policy,
        clock,
        tls_provider,
        pool => {
          serve(async fn(request) {
            pool
            .execute_body(request)
            .unwrap_or_error()
            .map_body(body => @client_api.IncomingBody::wrap(body))
          })
        },
        options={
          max_connections,
          tls,
          session: {
            ..defaults.session,
            limits: options.limits,
            max_concurrent_streams: defaults.session.max_concurrent_streams
            .min(options.limits.max_concurrent_requests)
            .min(options.limits.max_streams),
            read_size: defaults.session.read_size.min(
              options.limits.max_buffer_bytes,
            ),
            h2_receive_window_bytes: defaults.session.h2_receive_window_bytes.min(
              options.limits.max_buffer_bytes,
            ),
            read_timeout_ms: options.timeouts.response_body_ms,
            write_timeout_ms: options.timeouts.request_body_ms,
          },
          connect_options: {
            ..defaults.connect_options,
            timeout_ms: options.timeouts.connect_ms,
          },
          resolve_options: {
            ..defaults.resolve_options,
            timeout_ms: options.timeouts.resolve_ms,
          },
          tls_timeout_ms: options.timeouts.tls_ms,
        },
      )
    }
    Http3 =>
      with_http3_pool(
        resolver,
        policy,
        pool => {
          serve(async fn(request) {
            let response = pool.send(request) catch {
              error => raise native_http3_error(error)
            }
            response.map_body(body => @client_api.IncomingBody::wrap(body))
          })
        },
        tls~,
        max_connections~,
        limits=options.limits,
        resolve_options={
          ..@transport.ResolveOptions::defaults(),
          timeout_ms: options.timeouts.resolve_ms,
        },
        handshake_timeout_ms=options.timeouts.tls_ms.unwrap_or(10000),
      )
  }
}

///|
fn native_http3_error(error : Error) -> Error {
  match error {
    @service.Http3ClientError::Goaway(id) =>
      @client_api.ClientError::ClientHttp3(Goaway(id))
    @service.Http3ClientError::PeerReset(id, code) if code ==
      @http3.H3ErrorCode::H3RequestRejected.wire_value() =>
      @client_api.ClientError::ClientH3Rejected(id)
    @service.Http3ClientError::PeerReset(id, code) =>
      @client_api.ClientError::ClientHttp3(PeerReset(id, code))
    @http3.Http3Error::Http3StreamError(id, H3RequestRejected, _) =>
      @client_api.ClientError::ClientH3Rejected(id)
    @http3.Http3SessionError::Http3Transport(cause) => native_http3_error(cause)
    @http3.Http3SessionError::Http3Protocol(cause) => native_http3_error(cause)
    @quic.QuicError::Transport(cause) => native_http3_error(cause)
    @quic.QuicError::Tls(cause) => @client_api.ClientError::ClientTls(cause)
    @quic.QuicError::Policy(cause) | @transport.TransportError::Policy(cause) =>
      @client_api.ClientError::ClientPolicy(cause)
    @transport.TransportError::Failed(op, message) =>
      @client_api.ClientError::ClientTransport(Failed(op, message))
    @transport.TransportError::Timeout(op) =>
      @client_api.ClientError::ClientTransport(Timeout(op))
    @transport.TransportError::SystemFailure(op, code, message) =>
      @client_api.ClientError::ClientTransport(SystemFailure(op, code, message))
    @transport.TransportError::NativeFailure(op, code, status, message) =>
      @client_api.ClientError::ClientTransport(
        NativeFailure(op, code, status, message),
      )
    _ => error
  }
}
