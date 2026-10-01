///|
test "test_support: fixed clock and entropy are deterministic test capabilities" {
  let clock = @test_support.FixedClock::new(10, 20)
  assert_eq(clock.monotonic_millis(), 10)
  assert_eq(clock.advance(1999), Ok(()))
  assert_eq(clock.monotonic_millis(), 2009)
  assert_eq(clock.wall_clock_seconds(), 21)
  let entropy = @test_support.ZeroEntropy::new()
  let bytes = FixedArray::make(4, b'\x01')
  assert_eq(entropy.fill(bytes), Ok(()))
  assert_eq(bytes[0], b'\x00')
}

///|
async test "test_support: memory datagram enforces explicit limits" {
  let endpoint = @types.Endpoint::new("udp", "example.test", 443).unwrap()
  let socket = @test_support.MemoryDatagramSocket::new(max_datagram_size=8).unwrap()
  socket.inject(@transport.Datagram::new(b"in", endpoint)).unwrap()
  let incoming = socket.receive(8).unwrap()
  assert_eq(incoming.payload(), b"in")
  socket.send(endpoint, b"out").unwrap()
  assert_eq(socket.sent().length(), 1)
  assert_true(socket.send(endpoint, b"123456789") is Err(InvalidDatagramSize))
  socket.close()
  assert_true(socket.send(endpoint, b"x") is Err(Closed))
}
