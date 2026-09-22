///|
test "transport: endpoint and options validation are finite" {
  let endpoint = @transport.Endpoint::new("HTTPS", "Example.COM", 443).unwrap()
  assert_eq(endpoint.scheme(), "https")
  assert_eq(endpoint.authority(), "example.com:443")
  assert_true(@transport.Endpoint::new("1http", "example.test", 443) is Err(_))
  assert_true(@transport.Endpoint::new("http", "bad host", 80) is Err(_))
  assert_true(
    @transport.Endpoint::new("http", "example.test:443", 80) is Err(_),
  )
  assert_true(@transport.Endpoint::new("http", "[not-an-ip]", 80) is Err(_))
  assert_eq(
    @transport.Endpoint::new("http", "2001:DB8::1", 80).unwrap().authority(),
    "[2001:db8::1]:80",
  )
  assert_eq(
    @transport.Endpoint::new("http", "[2001:DB8::1]", 80).unwrap().authority(),
    "[2001:db8::1]:80",
  )
  assert_true(@transport.Endpoint::new("http", "example.test", 0) is Err(_))
  assert_eq(@transport.ConnectOptions::defaults().validate(), Ok(()))
  assert_true(
    @transport.ConnectOptions::{
      timeout_ms: Some(0),
      idle_timeout_ms: None,
      local_host: None,
      local_port: None,
    }.validate()
    is Err(_),
  )
}

///|
test "transport: policy denial is not a transport failure" {
  let endpoint = @transport.Endpoint::new("https", "example.test", 443).unwrap()
  let policy = @transport.DenyAllPolicy::new()
  assert_true(policy.authorize(endpoint, Connect) is Err(Denied(Connect, _)))
}

///|
test "transport: fixed clock and entropy are deterministic test capabilities" {
  let clock = @transport.FixedClock::new(10, 20)
  assert_eq(clock.monotonic_millis(), 10)
  assert_eq(clock.advance(1999), Ok(()))
  assert_eq(clock.monotonic_millis(), 2009)
  assert_eq(clock.wall_clock_seconds(), 21)
  let entropy = @transport.ZeroEntropy::new()
  let bytes = FixedArray::make(4, b'\x01')
  assert_eq(entropy.fill(bytes), Ok(()))
  assert_eq(bytes[0], b'\x00')
}

///|
async test "transport: resolver and memory datagram enforce explicit limits" {
  let address = @transport.IpAddress::parse("127.0.0.1").unwrap()
  let resolver = @transport.StaticResolver::new([("Example.test", [address])])
  let resolved = resolver
    .resolve("example.test", @transport.ResolveOptions::defaults())
    .unwrap()
  assert_eq(resolved.length(), 1)
  assert_true(
    resolver.resolve("example.test", { timeout_ms: None, max_results: 0, })
    is Err(InvalidResolveOptions),
  )
  let endpoint = @transport.Endpoint::new("udp", "example.test", 443).unwrap()
  let socket = @transport.MemoryDatagramSocket::new(max_datagram_size=8).unwrap()
  socket.inject(@transport.Datagram::new(b"in", endpoint)).unwrap()
  let incoming = socket.receive(8).unwrap()
  assert_eq(incoming.payload(), b"in")
  socket.send(endpoint, b"out").unwrap()
  assert_eq(socket.sent().length(), 1)
  assert_true(socket.send(endpoint, b"123456789") is Err(InvalidDatagramSize))
  socket.close()
  assert_true(socket.send(endpoint, b"x") is Err(Closed))
}

///|
test "transport: resolved addresses are unambiguous numeric IP literals" {
  assert_eq(
    @transport.IpAddress::parse("192.0.2.1").unwrap().value(),
    "192.0.2.1",
  )
  assert_eq(
    @transport.IpAddress::parse("2001:DB8::1").unwrap().value(),
    "2001:db8::1",
  )
  assert_true(@transport.IpAddress::parse("::ffff:192.0.2.1") is Ok(_))
  for
    invalid in [
      "example.test", "127.1", "127.00.0.1", "256.0.0.1", "1.2.3.4.5", ":1", "1:",
      "1::2::3", "1:2:3:4:5:6:7:8:9", "[::1]",
    ] {
    assert_true(@transport.IpAddress::parse(invalid) is Err(_))
  }
}

///|
async test "transport: stream failures close exactly once and bound reads" {
  let endpoint = @transport.Endpoint::new("http", "example.test", 80).unwrap()
  let mut read_calls = 0
  let mut close_calls = 0
  let connection = @transport.StreamConnection::new(
    endpoint,
    fn(_) {
      read_calls += 1
      Err(Failed(Receive, "injected"))
    },
    fn(_) { Ok(()) },
    fn() { close_calls += 1 },
  )
  assert_true(connection.read(8) is Err(Failed(Receive, _)))
  assert_eq(read_calls, 1)
  assert_eq(close_calls, 1)
  assert_eq(connection.read(8), Err(Closed))
  connection.close()
  assert_eq(close_calls, 1)

  let mut close_on_write = 0
  let write_failure = @transport.StreamConnection::new(
    endpoint,
    fn(_) { Ok(None) },
    fn(_) { Err(Failed(Send, "injected")) },
    fn() { close_on_write += 1 },
  )
  assert_true(write_failure.write(b"x") is Err(Failed(Send, _)))
  assert_eq(close_on_write, 1)
  assert_true(write_failure.write(b"x") is Err(Closed))
}
