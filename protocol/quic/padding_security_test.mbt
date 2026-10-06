///|
test "quic public builders terminate across Retry-token padding gaps" {
  let destination = @quic.ConnectionId::new(b"destinid").unwrap()
  let source = @quic.ConnectionId::new(b"sourceid").unwrap()
  let keys = @quic.quic_initial_packet_key(destination, Client).unwrap()
  let token = Bytes::from_array(FixedArray::make(1110, b't'))
  for payload in [b"", b"x"] {
    let options = {
      ..@quic.QuicInitialPacketOptions::defaults(destination, source, 0L),
      token,
    }
    let initial = @quic.quic_build_initial_packet(keys, options, payload).unwrap()
    assert_eq(initial.length(), 1201)
    let long = @quic.quic_build_long_packet(
      keys,
      0,
      1,
      destination,
      source,
      token,
      0L,
      4,
      payload,
      min_datagram_size=1200,
    ).unwrap()
    assert_eq(long.length(), 1201)
    assert_true(
      @quic.quic_build_initial_packet(
        keys,
        { ..options, max_datagram_size: 1200, },
        payload,
      )
      is Err(InvalidPacket(_)),
    )
    assert_true(
      @quic.quic_build_long_packet(
        keys,
        0,
        1,
        destination,
        source,
        token,
        0L,
        4,
        payload,
        min_datagram_size=1200,
        max_datagram_size=1200,
      )
      is Err(InvalidPacket(_)),
    )
    let (offset, _) = @quic.quic_long_header_packet_layout(initial).unwrap()
    let opened = @quic.quic_open_packet_with_keys(
      keys, initial, offset, -1L, true,
    ).unwrap()
    assert_eq(opened.payload()[:payload.length()].to_owned(), payload)
  }
}

///|
test "quic padding chooses a representable size at both small length boundaries" {
  let destination = @quic.ConnectionId::new(b"destinid").unwrap()
  let source = @quic.ConnectionId::new(b"sourceid").unwrap()
  let keys = @quic.quic_initial_packet_key(destination, Client).unwrap()
  for
    (minimum, expected) in [
      (88, 88),
      (89, 90),
      (90, 90),
      (16409, 16409),
      (16410, 16412),
      (16411, 16412),
      (16412, 16412),
    ] {
    let packet = @quic.quic_build_long_packet(
      keys,
      0,
      1,
      destination,
      source,
      b"",
      0L,
      4,
      b"x",
      min_datagram_size=minimum,
      max_datagram_size=expected,
    ).unwrap()
    assert_eq(packet.length(), expected)
    let options = {
      ..@quic.QuicInitialPacketOptions::defaults(destination, source, 0L),
      min_datagram_size: minimum,
      max_datagram_size: expected,
    }
    assert_eq(
      @quic.quic_build_initial_packet(keys, options, b"x").unwrap().length(),
      expected,
    )
  }
}
