///|
test "quic packet protection: short header round trip and key phase" {
  let dcid = @quic.ConnectionId::new(b"\x01\x02\x03\x04").unwrap()
  let keys = @quic.quic_initial_packet_key(dcid, Client).unwrap()
  let prefix = b"\x40\x01\x02\x03\x04"
  let packet = @quic.quic_protect_packet_with_keys(
    keys, prefix, 0x1234L, 2, b"HTTP/3 DATA payload", false,
  ).unwrap()
  let opened = @quic.quic_open_packet_with_keys(keys, packet, 5, -1L, false).unwrap()
  assert_eq(opened.packet_number(), 0x1234L)
  assert_eq(opened.payload(), b"HTTP/3 DATA payload")
  assert_eq(opened.packet_number_length(), 2)
  assert_true(!opened.key_phase())
}

///|
test "quic packet protection: long header round trip and tamper rejection" {
  let dcid = @quic.ConnectionId::new(b"\x83\x94\xc8\xf0\x3e\x51\x57\x08").unwrap()
  let keys = @quic.quic_initial_packet_key(dcid, Client).unwrap()
  // Initial long header through the payload-length field. The length value is
  // intentionally supplied by the packet builder in a real driver.
  let prefix = Bytes::from_array([
    0xc0, 0, 0, 0, 1, 8, 0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08, 4, 0x01,
    0x02, 0x03, 0x04, 0, // token length
     0x26, // packet number (2) + ciphertext (20-byte payload + tag)
  ])
  let packet = @quic.quic_protect_packet_with_keys(
    keys, prefix, 2L, 2, b"crypto frame payload", true,
  ).unwrap()
  let opened = @quic.quic_open_packet_with_keys(
    keys,
    packet,
    prefix.length(),
    1L,
    true,
  ).unwrap()
  assert_eq(opened.packet_number(), 2L)
  assert_eq(opened.payload(), b"crypto frame payload")
  let tampered_bytes = packet.to_array()
  tampered_bytes[tampered_bytes.length() - 1] = tampered_bytes[tampered_bytes.length() -
    1] ^
    1
  let tampered = Bytes::from_array(tampered_bytes)
  assert_true(
    @quic.quic_open_packet_with_keys(keys, tampered, prefix.length(), 1L, true)
    is Err(_),
  )
}

///|
test "quic packet number reconstruction: RFC 9000 window selection" {
  assert_eq(
    @quic.quic_reconstruct_packet_number(0xffL, 1, 0xffL).unwrap(),
    0xffL,
  )
  assert_eq(
    @quic.quic_reconstruct_packet_number(0x00L, 1, 0x17fL).unwrap(),
    0x200L,
  )
  assert_eq(
    @quic.quic_reconstruct_packet_number(0x00L, 1, 0x1ffL).unwrap(),
    0x200L,
  )
  assert_eq(
    @quic.quic_reconstruct_packet_number(0x10L, 2, 0x1ffL).unwrap(),
    0x10L,
  )
  assert_true(@quic.quic_reconstruct_packet_number(0x100L, 1, 0L) is Err(_))
  assert_true(@quic.quic_reconstruct_packet_number(0L, 5, -1L) is Err(_))
}

///|
test "quic packet protection: rejects malformed offsets and reserved bits" {
  let dcid = @quic.ConnectionId::new(b"\x01\x02\x03\x04").unwrap()
  let keys = @quic.quic_initial_packet_key(dcid, Client).unwrap()
  assert_true(
    @quic.quic_open_packet_with_keys(keys, b"short", 5, -1L, false) is Err(_),
  )
  assert_true(
    @quic.quic_protect_packet_with_keys(keys, b"\x00", 0L, 1, b"x", false)
    is Err(_),
  )
}

///|
test "quic packet protection: caller controls sampling padding" {
  let dcid = @quic.ConnectionId::new(b"\x01\x02\x03\x04").unwrap()
  let keys = @quic.quic_initial_packet_key(dcid, Client).unwrap()
  assert_true(
    @quic.quic_protect_packet_with_keys(
      keys, b"\x40\x01\x02\x03\x04", 0L, 1, b"x", false,
    )
    is Err(_),
  )
}

///|
test "quic packet builder: Initial length and 1200-byte padding are exact" {
  let destination = @quic.ConnectionId::new(b"destination").unwrap()
  let source = @quic.ConnectionId::new(b"source").unwrap()
  let keys = @quic.quic_initial_packet_key(destination, Client).unwrap()
  let options = @quic.QuicInitialPacketOptions::defaults(
    destination, source, 7L,
  )
  let packet = @quic.quic_build_initial_packet(keys, options, b"hello").unwrap()
  assert_true(packet.length() >= 1200)
  let (offset, payload_length) = @quic.quic_long_header_packet_layout(packet).unwrap()
  assert_eq(offset + payload_length.to_int(), packet.length())
  let opened = @quic.quic_open_packet_with_keys(keys, packet, offset, -1L, true).unwrap()
  assert_eq(opened.packet_number(), 7L)
  assert_eq(opened.payload()[:5].to_owned(), b"hello")
}
