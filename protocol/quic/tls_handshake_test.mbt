///|
test "quic TLS boundary: reassembly feeds complete messages at separate encryption levels" {
  let wire = @quic.QuicCryptoReassembler::new(max_bytes=32).unwrap()
  let tls = @quic.QuicHandshakeInput::new(max_bytes_per_level=32).unwrap()
  assert_eq(wire.feed(4L, b"hello").unwrap(), [])
  let chunks = wire.feed(0L, b"\x01\x00\x00\x05").unwrap()
  assert_eq(chunks.length(), 1)
  let messages = tls.feed(Initial, 0L, chunks[0]).unwrap()
  assert_eq(messages.length(), 1)
  assert_eq(messages[0].encoded, b"\x01\x00\x00\x05hello")
  assert_eq(tls.feed(Handshake, 0L, b"\x08\x00\x00\x00").unwrap().length(), 1)
  tls.finish_level(Initial).unwrap()
  assert_true(
    tls.feed(Application, 0L, b"\x18\x00\x00\x01\x00") is Err(Tls(Alert(10))),
  )
}

///|
test "quic TLS boundary: directional traffic secrets cannot be skipped or reinstalled" {
  let endpoint = @types.Endpoint::new("udp", "example.test", 443).unwrap()
  let id = @quic.ConnectionId::new(b"server-id").unwrap()
  let driver = @quic.QuicDatagramDriver::new(Client, endpoint, id, id, id).unwrap()
  let secret = FixedArray::make(32, b'\x11').unsafe_reinterpret_as_bytes()
  assert_true(
    driver.install_traffic_secret(QuicApplication, QuicWriteSecret, secret)
    is Err(Unsupported(_)),
  )
  assert_true(
    driver.install_traffic_secret(QuicInitial, QuicWriteSecret, secret)
    is Err(Unsupported(_)),
  )
  driver.install_traffic_secret(QuicHandshake, QuicReadSecret, secret).unwrap()
  driver.install_traffic_secret(QuicHandshake, QuicWriteSecret, secret).unwrap()
  assert_true(
    driver.install_traffic_secret(QuicHandshake, QuicWriteSecret, secret)
    is Err(Unsupported(_)),
  )
  driver
  .install_traffic_secret(QuicApplication, QuicReadSecret, secret)
  .unwrap()
  driver
  .install_traffic_secret(QuicApplication, QuicWriteSecret, secret)
  .unwrap()
  assert_eq(driver.state(), Handshaking)
  assert_true(
    driver.install_traffic_secret(QuicApplication, QuicWriteSecret, secret)
    is Err(Unsupported(_)),
  )
}
