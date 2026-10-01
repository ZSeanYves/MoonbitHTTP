///|
test "quic TLS framing: fragments and coalesced messages preserve complete encoded bytes" {
  let decoder = @tls.QuicHandshakeDecoder::new(QuicHandshake).unwrap()
  assert_eq(decoder.feed(0L, b"\x08\x00").unwrap(), [])
  let messages = decoder.feed(2L, b"\x00\x02ab\x14\x00\x00\x01c").unwrap()
  assert_eq(messages.length(), 2)
  assert_eq(messages[0].message_type, 8)
  assert_eq(messages[0].encoded, b"\x08\x00\x00\x02ab")
  assert_eq(messages[1].encoded, b"\x14\x00\x00\x01c")
  decoder.finish().unwrap()
  assert_true(decoder.feed(11L, b"x") is Err(HandshakeFailed(_)))
}

///|
test "quic TLS framing: bounds and errors are sticky" {
  let oversized = @tls.QuicHandshakeDecoder::new(QuicInitial, max_bytes=8).unwrap()
  assert_true(
    oversized.feed(0L, b"\x01\x00\x00\x05") is Err(HandshakeFailed(_)),
  )
  assert_true(
    oversized.feed(0L, b"\x01\x00\x00\x00") is Err(HandshakeFailed(_)),
  )
  let count = @tls.QuicHandshakeDecoder::new(QuicInitial, max_messages=1).unwrap()
  assert_eq(count.feed(0L, b"\x01\x00\x00\x00").unwrap().length(), 1)
  assert_true(count.feed(4L, b"\x02\x00\x00\x00") is Err(HandshakeFailed(_)))
  let gap = @tls.QuicHandshakeDecoder::new(QuicHandshake).unwrap()
  assert_true(gap.feed(1L, b"x") is Err(HandshakeFailed(_)))
  let truncated = @tls.QuicHandshakeDecoder::new(QuicHandshake).unwrap()
  ignore(truncated.feed(0L, b"\x08\x00\x00\x01").unwrap())
  assert_true(truncated.finish() is Err(HandshakeFailed(_)))
}

///|
test "quic TLS framing: KeyUpdate, EndOfEarlyData and wrong-level messages fail closed" {
  for
    (level, message) in [
      (@transport.QuicEncryptionLevel::QuicApplication, b"\x18\x00\x00\x01\x00"),
      (QuicHandshake, b"\x05\x00\x00\x00"),
      (QuicInitial, b"\x14\x00\x00\x00"),
      (QuicApplication, b"\x0d\x00\x00\x00"),
    ] {
    let decoder = @tls.QuicHandshakeDecoder::new(level).unwrap()
    assert_true(decoder.feed(0L, message) is Err(Alert(10)))
  }
  let ticket = @tls.QuicHandshakeDecoder::new(QuicApplication).unwrap()
  assert_eq(ticket.feed(0L, b"\x04\x00\x00\x00").unwrap().length(), 1)
}
