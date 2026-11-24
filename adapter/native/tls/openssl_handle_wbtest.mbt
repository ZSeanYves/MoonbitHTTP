///|
test "native TLS: close is idempotent and native handles cannot be reused" {
  let ssl = openssl_new(
    @packet_crypto.openssl_symbols(),
    false,
    false,
    false,
    0x0304,
    0,
    b"localhost",
    false,
    b"",
    b"",
    false,
    false,
    b"",
    b"",
    b"",
    b"\x02h2",
  )
  assert_true(ssl.ready())
  ssl.close()
  ssl.close()
  let count = Ref(123)
  assert_false(ssl.ready())
  assert_eq(ssl.handshake(), -1)
  assert_eq(ssl.feed(b"after close"), -1)
  assert_eq(ssl.drain(), b"")
  assert_eq(ssl.read(FixedArray::make(8, b'\x00'), count), -1)
  assert_eq(count.val, 0)
  assert_eq(ssl.write(b"after close", 0, 11, count), -1)
  assert_eq(ssl.version(), 0)
  assert_eq(ssl.cipher(), b"")
  assert_eq(ssl.alpn(), b"")
  assert_false(ssl.peer_authenticated())
}
