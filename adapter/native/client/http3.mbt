///|
/// Connect one policy-authorized numeric UDP endpoint. Supply the origin's
/// TLS identity in options (TlsOptions::for_quic enables peer verification).
/// The callback owns application streams within this authenticated connection.
pub async fn[P : @transport.NetworkPolicy, X] with_http3_connection(
  endpoint : @types.Endpoint,
  policy : P,
  options : @transport.TlsOptions,
  run : async (@service.Http3ConnectionIo) -> X,
  limits~ : @types.Limits = @types.Limits::defaults(),
  qpack_limits~ : @http3.QpackLimits = @http3.QpackLimits::defaults(),
  transport_params~ : @quic.QuicTransportParams = @quic.QuicTransportParams::defaults(),
  handshake_timeout_ms~ : Int32? = Some(10000),
  shutdown_timeout_ms~ : Int32 = 5000,
) -> X {
  let entropy = @tls_native.NativeEntropy::new()
  let clock = @transport_native.NativeClock::new()
  let original = @quic.ConnectionId::random(entropy).unwrap_or_error()
  let local_id = @quic.ConnectionId::random(entropy).unwrap_or_error()
  let packets = @quic.QuicDatagramDriver::new(
    Client,
    endpoint,
    original,
    local_id,
    original,
    now_ms=clock.monotonic_millis(),
    limits={
      ..@quic.QuicLimits::defaults(),
      max_datagram_size: limits.max_datagram_bytes,
    },
    transport_params~,
    authorize=fn(peer, operation) { policy.authorize(peer, operation) },
  ).unwrap_or_error()
  packets.enable_connection_id_issuance(entropy).unwrap_or_error()
  let provider = @tls_native.NativeQuicTlsProvider::new()
  defer provider.close()
  let tls = @quic.QuicTlsDriver::new(packets, provider).unwrap_or_error()
  let socket = @transport_native.UdpSocket::connect(
    endpoint,
    policy,
    max_datagram_size=limits.max_datagram_bytes,
  ).unwrap_or_error()
  @service.with_http3_connection(
    tls,
    socket,
    clock,
    options,
    run,
    limits~,
    qpack_limits~,
    handshake_timeout_ms~,
    shutdown_timeout_ms~,
  )
}

///|
/// Use concurrent HTTP requests on one verified HTTPS origin. An explicit
/// resolver enables hostname endpoints. All addresses share the handshake
/// timeout, and the TLS options retain the authenticated origin identity.
pub async fn[P : @transport.NetworkPolicy, X] with_http3_client_connection(
  endpoint : @types.Endpoint,
  policy : P,
  options : @transport.TlsOptions,
  run : async (@service.Http3ClientConnection) -> X,
  origin_port~ : Int32? = None,
  on_state_change~ : () -> Unit = fn() {  },
  resolver~ : &@transport.NameResolver? = None,
  resolve_options~ : @transport.ResolveOptions = @transport.ResolveOptions::defaults(),
  limits~ : @types.Limits = @types.Limits::defaults(),
  qpack_limits~ : @http3.QpackLimits = @http3.QpackLimits::defaults(),
  transport_params~ : @quic.QuicTransportParams = @quic.QuicTransportParams::defaults(),
  handshake_timeout_ms~ : Int32? = Some(10000),
  shutdown_timeout_ms~ : Int32 = 5000,
) -> X {
  if !options.verify_peer {
    raise @service.Http3ClientError::InvalidOrigin
  }
  let candidates = match resolver {
    None => [endpoint]
    Some(resolver) =>
      @transport.resolve_endpoints(
        endpoint,
        async fn(host, options) {
          match policy.authorize(endpoint, Resolve) {
            Err(error) => Err(Policy(error))
            Ok(_) => resolver.resolve(host, options)
          }
        },
        options=resolve_options,
      ).unwrap_or_error()
  }
  let clock = @transport_native.NativeClock::new()
  let started = clock.monotonic_millis()
  for index = 0; ; index = index + 1 {
    let remaining = candidates.length() - index
    let timeout = if candidates.length() > 1 &&
      handshake_timeout_ms is Some(ms) &&
      ms > 0 {
      let budget = ms.to_int64() - (clock.monotonic_millis() - started)
      if budget <= 0L {
        raise @transport.TransportError::Timeout(Connect)
      }
      Some((budget / remaining.to_int64()).max(1L).to_int())
    } else {
      handshake_timeout_ms
    }
    let mut authenticated = false
    try {
      return with_http3_connection(
        candidates[index],
        policy,
        options,
        async fn(io) {
          authenticated = true
          @service.with_http3_client_connection(
            io,
            run,
            origin_port~,
            on_state_change~,
          )
        },
        limits~,
        qpack_limits~,
        transport_params={
          ..transport_params,
          initial_max_stream_data_bidi_local: transport_params.initial_max_stream_data_bidi_local.min(
            limits.max_buffer_bytes.to_int64(),
          ),
        },
        handshake_timeout_ms=timeout,
        shutdown_timeout_ms~,
      )
    } catch {
      error if !authenticated && remaining > 1 && h3_try_next_address(error) =>
        continue
      error => raise error
    }
  }
}

///|
/// Policy denial and a path that cannot carry UDP apply to this address.
/// An authentication error or a failure from the callback ends the scope.
fn h3_try_next_address(error : Error) -> Bool {
  match error {
    @async.TimeoutError
    | @quic.QuicError::Policy(Denied(QuicEndpoint, _))
    | @transport.TransportError::Policy(Denied(QuicEndpoint, _)) => true
    @transport.TransportError::SystemFailure(op, _, _)
    | @transport.TransportError::NativeFailure(op, _, _, _)
    | @transport.TransportError::Failed(op, _)
    | @transport.TransportError::Timeout(op) => op is (Connect | Send | Receive)
    @quic.QuicError::Transport(cause) => h3_try_next_address(cause)
    _ => false
  }
}

///|
/// Open a bounded pool for absolute HTTPS requests. Each origin uses its own
/// verified TLS identity and UDP connection. An explicit server name pins
/// this pool to that hostname while still isolating distinct origin ports.
pub async fn[R : @transport.NameResolver, P : @transport.NetworkPolicy, X] with_http3_pool(
  resolver : R,
  policy : P,
  run : async (@client_api.Http3Client) -> X,
  tls~ : @transport.TlsOptions = @transport.TlsOptions::quic_defaults(),
  max_connections~ : Int32 = 32,
  resolve_options~ : @transport.ResolveOptions = @transport.ResolveOptions::defaults(),
  limits~ : @types.Limits = @types.Limits::defaults(),
  qpack_limits~ : @http3.QpackLimits = @http3.QpackLimits::defaults(),
  transport_params~ : @quic.QuicTransportParams = @quic.QuicTransportParams::defaults(),
  handshake_timeout_ms~ : Int32? = Some(10000),
  shutdown_timeout_ms~ : Int32 = 5000,
) -> X {
  if !tls.verify_peer {
    raise @service.Http3ClientError::InvalidOrigin
  }
  @client_api.with_http3_pool(
    async fn(endpoint, ready, changed) {
      let host = endpoint.transport.host()
      let peer = @types.Endpoint::new("udp", host, endpoint.transport.port()).unwrap_or_error()
      with_http3_client_connection(
        peer,
        policy,
        { ..tls, server_name: Some(host), },
        ready,
        resolver=Some(resolver),
        on_state_change=changed,
        resolve_options~,
        limits~,
        qpack_limits~,
        transport_params~,
        handshake_timeout_ms~,
        shutdown_timeout_ms~,
      )
    },
    run,
    max_connections~,
    server_name=tls.server_name,
  )
}
