///|
fn[T, E : Error] h3_native_value(value : Result[T, E]) -> T raise E {
  match value {
    Ok(value) => value
    Err(error) => raise error
  }
}

///|
fn new_connection_id(
  entropy : @tls_native.NativeEntropy,
) -> @quic.ConnectionId raise {
  let bytes = FixedArray::make(16, b'\x00')
  h3_native_value(@transport.Entropy::fill(entropy, bytes))
  h3_native_value(@quic.ConnectionId::new(bytes.unsafe_reinterpret_as_bytes()))
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
  handshake_timeout_ms? : Int = 10000,
  shutdown_timeout_ms? : Int = 5000,
) -> X {
  let entropy = @tls_native.NativeEntropy::new()
  let clock = @transport_native.NativeClock::new()
  let original = new_connection_id(entropy)
  let local_id = new_connection_id(entropy)
  let packets = h3_native_value(
    @quic.QuicDatagramDriver::new(
      Client,
      endpoint,
      original,
      local_id,
      original,
      now_ms=clock.monotonic_millis(),
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
