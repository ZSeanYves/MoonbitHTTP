///|
async test "native transport: resolver validates and bounds results" {
  let resolver = @transport.NativeResolver::new()
  assert_true(
    @transport_api.NameResolver::resolve(resolver, "localhost", {
      timeout_ms: Some(5000),
      max_results: 1,
    })
    is Ok([_]),
  )
  let numeric = @transport_api.NameResolver::resolve(resolver, "192.0.2.1", {
    timeout_ms: Some(5000),
    max_results: 1,
  }).unwrap()
  assert_eq(numeric.length(), 1)
  assert_eq(numeric[0].value(), "192.0.2.1")
  assert_true(
    @transport_api.NameResolver::resolve(resolver, "localhost", {
      timeout_ms: Some(5000),
      max_results: 0,
    })
    is Err(InvalidResolveOptions),
  )
}

///|
async test "native transport: clock separates deadline and wall time sources" {
  let clock = @transport.NativeClock::new()
  let before = @transport_api.Clock::monotonic_millis(clock)
  @async.sleep(2)
  let after = @transport_api.Clock::monotonic_millis(clock)
  assert_true(before >= 0L)
  assert_true(after >= before)
  assert_true(@transport_api.Clock::wall_clock_seconds(clock) > 1577836800L)
}

///|
async test "native UDP: allowed numeric endpoint creates a closable socket" {
  let endpoint = @types.Endpoint::new("udp", "127.0.0.1", 443).unwrap()
  let socket = @transport.UdpSocket::connect(
    endpoint,
    @transport_api.AllowAllPolicy::new(),
  ).unwrap()
  @transport_api.DatagramSocket::close(socket)
  assert_true(
    @transport_api.DatagramSocket::send(socket, endpoint, b"closed")
    is Err(Closed),
  )
}
