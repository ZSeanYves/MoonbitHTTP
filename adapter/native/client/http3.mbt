///|
fn[T, E : Error] h3_native_value(value : Result[T, E]) -> T raise E {
  match value {
    Ok(value) => value
    Err(error) => raise error
  }
}

///|
/// Connect one policy-authorized numeric UDP endpoint. Supply the origin's
/// TLS identity in options (TlsOptions::for_quic enables peer verification).
/// The callback owns application streams within this authenticated connection.
pub async fn[P : @transport.NetworkPolicy, X] with_http3_connection(
  endpoint : @types.Endpoint,
  policy : P,
  options : @transport.TlsOptions,
  run : async (@service.H3ConnectionIo) -> X,
  limits? : @types.Limits = @types.Limits::defaults(),
  qpack_limits? : @http3.QpackLimits = @http3.QpackLimits::defaults(),
  transport_params? : @quic.QuicTransportParams = @quic.QuicTransportParams::defaults(),
  handshake_timeout_ms? : Int = 10000,
  shutdown_timeout_ms? : Int = 5000,
) -> X {
  let entropy = @tls_native.NativeEntropy::new()
  let clock = @transport_native.NativeClock::new()
  let original = h3_native_value(@quic.ConnectionId::random(entropy))
  let local_id = h3_native_value(@quic.ConnectionId::random(entropy))
  let packets = h3_native_value(
    @quic.QuicDatagramDriver::new(
      Client,
      endpoint,
      original,
      local_id,
      original,
      now_ms=clock.monotonic_millis(),
      transport_params~,
      authorize=fn(peer, operation) { policy.authorize(peer, operation) },
    ),
  )
  let provider = @tls_native.NativeQuicTlsProvider::new()
  defer provider.close()
  let tls = h3_native_value(@quic.QuicTlsDriver::new(packets, provider))
  let socket = h3_native_value(
    @transport_native.UdpSocket::connect(
      endpoint,
      policy,
      max_datagram_size=limits.max_datagram_bytes,
    ),
  )
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
pub async fn[P : @transport.NetworkPolicy, X] with_http3_client(
  endpoint : @types.Endpoint,
  policy : P,
  options : @transport.TlsOptions,
  run : async (@service.H3Client) -> X,
  origin_port? : Int? = None,
  resolver? : &@transport.NameResolver? = None,
  resolve_options? : @transport.ResolveOptions = @transport.ResolveOptions::defaults(),
  limits? : @types.Limits = @types.Limits::defaults(),
  qpack_limits? : @http3.QpackLimits = @http3.QpackLimits::defaults(),
  transport_params? : @quic.QuicTransportParams = @quic.QuicTransportParams::defaults(),
  handshake_timeout_ms? : Int = 10000,
  shutdown_timeout_ms? : Int = 5000,
) -> X {
  if !options.verify_peer {
    raise @service.H3ClientError::InvalidOrigin
  }
  let candidates = match resolver {
    None => [endpoint]
    Some(resolver) =>
      h3_native_value(
        @transport.resolve_endpoints(
          endpoint,
          async fn(host, options) {
            match policy.authorize(endpoint, Resolve) {
              Err(error) => Err(Policy(error))
              Ok(_) => resolver.resolve(host, options)
            }
          },
          options=resolve_options,
        ),
      )
  }
  let clock = @transport_native.NativeClock::new()
  let started = clock.monotonic_millis()
  for index = 0; ; index = index + 1 {
    let remaining = candidates.length() - index
    let timeout = if candidates.length() == 1 || handshake_timeout_ms <= 0 {
      handshake_timeout_ms
    } else {
      let budget = handshake_timeout_ms.to_int64() -
        (clock.monotonic_millis() - started)
      if budget <= 0L {
        raise @transport.TransportError::Timeout(Connect)
      }
      (budget / remaining.to_int64()).max(1L).to_int()
    }
    let mut authenticated = false
    try {
      return with_http3_connection(
        candidates[index],
        policy,
        options,
        async fn(io) {
          authenticated = true
          @service.with_h3_client(io, run, origin_port~)
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
