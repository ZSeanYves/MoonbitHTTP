///|
test "native transport: numeric endpoints bypass hostname resolution" {
  let ipv4 = @types.Endpoint::new("http", "127.0.0.1", 80).unwrap()
  let ipv6 = @types.Endpoint::new("http", "::1", 80).unwrap()
  let hostname = @types.Endpoint::new("http", "localhost", 80).unwrap()
  assert_true(numeric_socket_addr(ipv4) is Some(_))
  assert_true(numeric_socket_addr(ipv6) is Some(_))
  assert_eq(numeric_socket_addr(hostname), None)
}

///|
async test "native TCP: hostname requires explicit resolution" {
  let endpoint = @types.Endpoint::new("http", "localhost", 80).unwrap()
  assert_true(
    @transport_api.StreamConnector::connect(
      TcpConnector::new(),
      endpoint,
      @transport_api.ConnectOptions::defaults(),
    )
    is Err(Failed(Resolve, "TCP requires a numeric endpoint")),
  )
}

///|
async test "native transport: resolver validates and bounds results" {
  let resolver = NativeResolver::new()
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
  let clock = NativeClock::new()
  let before = @transport_api.Clock::monotonic_millis(clock)
  @async.sleep(2)
  let after = @transport_api.Clock::monotonic_millis(clock)
  assert_true(before >= 0L)
  assert_true(after >= before)
  assert_true(@transport_api.Clock::wall_clock_seconds(clock) > 1577836800L)
}

///|
async test "native UDP: policy rejection precedes endpoint and socket setup" {
  // A hostname is not a usable UDP socket address. The policy error must win,
  // proving denial happens before the socket-address and socket setup paths.
  let endpoint = @types.Endpoint::new("udp", "example.test", 443).unwrap()
  assert_true(
    UdpSocket::connect(endpoint, @transport_api.DenyAllPolicy::new())
    is Err(Policy(Denied(QuicEndpoint, "network policy denied operation"))),
  )
  assert_true(
    UdpSocket::connect(endpoint, @transport_api.AllowAllPolicy::new())
    is Err(Failed(Resolve, "UDP requires a numeric endpoint")),
  )
}

///|
async test "native UDP: allowed numeric endpoint creates a closable socket" {
  let endpoint = @types.Endpoint::new("udp", "127.0.0.1", 443).unwrap()
  let socket = UdpSocket::connect(
    endpoint,
    @transport_api.AllowAllPolicy::new(),
  ).unwrap()
  @transport_api.DatagramSocket::close(socket)
  assert_true(
    @transport_api.DatagramSocket::send(socket, endpoint, b"closed")
    is Err(Closed),
  )
}

///|
async test "native UDP: multicast is rejected after policy and before socket setup" {
  for
    host in [
      "224.0.0.1", "239.255.255.255", "ff02::1", "FF0E:0:0:0:0:0:0:1", "::ffff:224.0.0.1",
      "0:0:0:0:0:ffff:e000:1", "::FFFF:239.255.255.255",
    ] {
    let endpoint = @types.Endpoint::new("udp", host, 443).unwrap()
    assert_true(
      UdpSocket::connect(endpoint, @transport_api.DenyAllPolicy::new())
      is Err(Policy(Denied(QuicEndpoint, _))),
    )
    assert_true(
      UdpSocket::connect(endpoint, @transport_api.AllowAllPolicy::new())
      is Err(Failed(Connect, "connected UDP requires a unicast endpoint")),
    )
  }
}

///|
test "native UDP: unicast classification includes IPv4-mapped IPv6" {
  for
    host in [
      "127.0.0.1", "223.255.255.255", "240.0.0.1", "::1", "2001:db8::1", "::ffff:127.0.0.1",
      "0:0:0:0:0:ffff:7f00:1",
    ] {
    let endpoint = @types.Endpoint::new("udp", host, 443).unwrap()
    assert_true(
      !udp_connected_is_multicast(numeric_socket_addr(endpoint).unwrap()),
    )
  }
}
