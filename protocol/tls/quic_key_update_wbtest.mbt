///|
test "quic key update: independent OpenSSL HKDF vector and unchanged header protection" {
  // OpenSSL 3 HKDF EXPAND_ONLY, SHA256, info = uint16(32), uint8(13),
  // "tls13 quic ku", uint8(0). The input below is public test material.
  let original = derive_quic_packet_keys(
    b"\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f",
  ).unwrap()
  let next = original.next_application_keys().unwrap()
  assert_eq(
    next.secret,
    b"\x6a\x4c\xa3\x49\xa7\x7d\x86\x43\xfc\x3d\x19\xb9\x44\xd2\xc3\xde\x71\xcf\xc6\x72\x7d\xff\x19\x62\xe0\x0a\x30\xa6\xc5\xf4\xa7\xcd",
  )
  assert_eq(next.hp, original.hp)
  assert_true(next.key != original.key)
  assert_true(next.iv != original.iv)
  let ciphertext = next.seal(7L, b"header", b"payload").unwrap()
  assert_eq(next.open(7L, b"header", ciphertext).unwrap(), b"payload")
  assert_true(
    original.open(7L, b"header", ciphertext) is Err(PacketAuthenticationFailed),
  )
}
