///|
test "native transport: numeric endpoints bypass hostname resolution" {
  let ipv4 = @transport.Endpoint::new("http", "127.0.0.1", 80).unwrap()
  let ipv6 = @transport.Endpoint::new("http", "::1", 80).unwrap()
  let hostname = @transport.Endpoint::new("http", "localhost", 80).unwrap()
  assert_true(numeric_socket_addr(ipv4) is Some(_))
  assert_true(numeric_socket_addr(ipv6) is Some(_))
  assert_eq(numeric_socket_addr(hostname), None)
}

///|
async test "native transport: resolver validates and bounds results" {
  let resolver = NativeResolver::new()
  assert_true(
    @transport.NameResolver::resolve(resolver, "localhost", {
      timeout_ms: Some(5000),
      max_results: 1,
    })
    is Ok([_]),
  )
  let numeric = @transport.NameResolver::resolve(resolver, "192.0.2.1", {
    timeout_ms: Some(5000),
    max_results: 1,
  }).unwrap()
  assert_eq(numeric.length(), 1)
  assert_eq(numeric[0].value(), "192.0.2.1")
  assert_true(
    @transport.NameResolver::resolve(resolver, "localhost", {
      timeout_ms: Some(5000),
      max_results: 0,
    })
    is Err(InvalidResolveOptions),
  )
}

///|
async test "native transport: clock separates deadline and wall time sources" {
  let clock = NativeClock::new()
  let before = @transport.Clock::monotonic_millis(clock)
  @async.sleep(2)
  let after = @transport.Clock::monotonic_millis(clock)
  assert_true(before >= 0L)
  assert_true(after >= before)
  assert_true(@transport.Clock::wall_clock_seconds(clock) > 1577836800L)
}
