///|
fn tls_hex(value : String) -> Bytes {
  fn nibble(char : Char) -> Int {
    let value = char.to_int()
    if value >= 0x30 && value <= 0x39 {
      value - 0x30
    } else if value >= 0x61 && value <= 0x66 {
      value - 0x61 + 10
    } else {
      abort("invalid test hex")
    }
  }

  let output = FixedArray::make(value.length() / 2, b'\x00')
  for index in 0..<output.length() {
    output[index] = ((nibble(value.get_char(index * 2).unwrap()) << 4) |
    nibble(value.get_char(index * 2 + 1).unwrap())).to_byte()
  }
  output.unsafe_reinterpret_as_bytes()
}

///|
test "tls quic keys: RFC 9001 initial AEAD and header mask" {
  let (client, _) = @tls.quic_v1_initial_keys(tls_hex("8394c8f03e515708")).unwrap()
  let header = tls_hex("c300000001088394c8f03e5157080000449e00000002")
  let payload = b"quic initial crypto frame payload"
  let ciphertext = client.seal(2L, header, payload).unwrap()
  assert_eq(client.open(2L, header, ciphertext).unwrap(), payload)
  assert_true(
    client.open(3L, header, ciphertext) is Err(PacketAuthenticationFailed),
  )
  assert_eq(
    client
    .header_protection_mask(tls_hex("d1b1c98dd7689fb8ec11d242b123dc9b"))
    .unwrap(),
    tls_hex("437b9aec36"),
  )
}

///|
test "tls quic keys: reject invalid secrets, packet numbers, and tampering" {
  assert_true(
    @tls.derive_quic_packet_keys(b"short") is Err(InvalidTrafficSecret),
  )
  assert_true(@tls.quic_v1_initial_keys(b"") is Err(InvalidTrafficSecret))
  let (client, _) = @tls.quic_v1_initial_keys(tls_hex("8394c8f03e515708")).unwrap()
  assert_true(client.seal(-1L, b"header", b"body") is Err(InvalidPacketNumber))
  let ciphertext = client.seal(7L, b"header", b"body").unwrap()
  assert_true(
    client.open(7L, b"changed", ciphertext) is Err(PacketAuthenticationFailed),
  )
  assert_true(
    client.header_protection_mask(b"short") is Err(PacketProtectionFailed),
  )
}
