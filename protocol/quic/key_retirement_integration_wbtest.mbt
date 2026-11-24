///|
test "QUIC delays receiving 1-RTT until handshake completion even with installed keys" {
  let endpoint = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  let (client, server) = retirement_security_pair()
  client.establish().unwrap()
  let id = client.connection().open_bidirectional_stream().unwrap()
  guard client.send_stream(id, b"request", true, 0L).unwrap()
    is SendDatagram(_, packet) else {
    fail("expected an application packet")
  }
  assert_eq(server.on_datagram(endpoint, packet, 1L), Ok([PacketIgnored]))
  server.establish().unwrap()
  assert_true(
    server
    .on_datagram(endpoint, packet, 2L)
    .unwrap()
    .contains(StreamData(id, b"request", true)),
  )
}

///|
test "quic standalone establishment rejects late Initial close CRYPTO and negotiation" {
  let endpoint = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  let (client, server) = retirement_security_pair()
  ignore(client.send_frames(Initial, [Crypto(0L, b"initial")], 0L).unwrap())
  client.establish().unwrap()
  server.establish().unwrap()
  assert_eq(client.retransmissions.length(), 0)
  assert_eq(client.recovery.bytes_in_flight, 0L)
  let keys = quic_initial_packet_keys(server.local_connection_id()).unwrap()
  for
    (receiver, sender_id, key) in [
      (server, client.local_connection_id(), keys.0),
      (client, server.local_connection_id(), keys.1),
    ] {
    for
      frame in [Crypto(0L, b"forged"), ConnectionClose(true, 1L, 0L, b"forged")] {
      let packet = quic_build_long_packet(
        key,
        0,
        1,
        receiver.local_connection_id(),
        sender_id,
        b"",
        8L,
        4,
        quic_encode_frames([frame]).unwrap(),
        min_datagram_size=1200,
      ).unwrap()
      assert_eq(receiver.on_datagram(endpoint, packet, 1L), Ok([PacketIgnored]))
      assert_eq(receiver.state(), Established)
    }
  }
  let negotiation = quic_build_version_negotiation_packet(
    client.local_connection_id(),
    server.local_connection_id(),
    [2],
  ).unwrap()
  assert_eq(client.on_datagram(endpoint, negotiation, 2L), Ok([PacketIgnored]))
  guard client.send_frames(Application, [Ping], 3L).unwrap()
    is SendDatagram(_, valid) else {
    fail("expected application packet")
  }
  assert_true(server.on_datagram(endpoint, valid, 4L) is Ok(_))
  assert_true(client.handshake_receive_keys is Some(_))
}

///|
test "quic Initial retirement follows committed authenticated Handshake progress" {
  let endpoint = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  let (client, server) = retirement_security_pair()
  ignore(client.send_frames(Initial, [Crypto(0L, b"initial")], 0L).unwrap())
  assert_true(client.initial_receive_keys is Some(_))
  guard client.send_frames(Handshake, [Crypto(0L, b"finished")], 1L).unwrap()
    is SendDatagram(_, packet) else {
    fail("expected Handshake packet")
  }
  assert_true(client.initial_receive_keys is None)
  assert_false(client.retransmissions.any(fn(entry) { entry.space == Initial }))
  assert_true(server.initial_receive_keys is Some(_))
  let corrupted = packet.to_array()
  let last = corrupted.length() - 1
  corrupted[last] = corrupted[last] ^ 1
  assert_true(
    server.on_datagram(endpoint, Bytes::from_array(corrupted), 2L) is Err(_),
  )
  assert_true(server.initial_receive_keys is Some(_))
  ignore(server.on_datagram(endpoint, packet, 3L).unwrap())
  assert_true(server.initial_receive_keys is None)
  assert_true(server.handshake_receive_keys is Some(_))
}

///|
test "QUIC charges explicit and automatic PADDING through key retirement" {
  let (client, server) = retirement_security_pair()
  let ack = AckFrame::new(0L, 0L, [AckRange::new(0L, 0L).unwrap()]).unwrap()
  guard client.send_frames(Initial, [Ack(ack)], 0L).unwrap()
    is SendDatagram(_, initial) else {
    fail("expected client Initial")
  }
  assert_eq(initial.length(), 1200)
  assert_eq(client.recovery.bytes_in_flight(), 1200L)
  assert_true(client.recovery.oldest_probe_packet(Initial) is None)
  // A client Handshake retires Initial state. This tiny payload also needs
  // PADDING so header protection can take a complete sample.
  guard client.send_frames(Handshake, [Padding], 1501L).unwrap()
    is SendDatagram(_, handshake) else {
    fail("expected client Handshake")
  }
  assert_eq(client.recovery.bytes_in_flight(), handshake.length().to_int64())
  assert_true(client.retransmissions.is_empty())
  client.discard_packet_space(Handshake)
  assert_eq(client.recovery.bytes_in_flight(), 0L)
  // A server can emit an unpadded Initial ACK after receiving a client ping.
  let (other, _) = retirement_security_pair()
  guard other.send_frames(Initial, [Ping], 0L).unwrap() is SendDatagram(_, ping) else {
    fail("expected client ping")
  }
  guard server.on_datagram(server.endpoint(), ping, 1L).unwrap()
    is [SendDatagram(_, reply)] else {
    fail("expected server ACK")
  }
  assert_true(reply.length() < 1200)
  assert_eq(server.recovery.bytes_in_flight(), 0L)
}

///|
test "QUIC retries a padded Initial ACK when receive processing releases a recovery slot" {
  let (client, server) = retirement_security_pair()
  client.recovery = QuicRecovery::new(config={
    ..QuicRecoveryConfig::defaults(),
    max_tracked_packets: 1,
  }).unwrap()
  guard client.send_frames(Initial, [Padding], 0L).unwrap()
    is SendDatagram(_, padding) else {
    fail("expected padded Initial")
  }
  // The padding reaches the tracking limit, so its peer elicits feedback.
  // Hold that ACK until a later incoming PING also needs a reply.
  guard server.on_datagram(server.endpoint(), padding, 1L).unwrap()
    is [SendDatagram(_, ack)] else {
    fail("expected ACK for the full padding flight")
  }
  guard server.send_frames(Initial, [Ping], 2L).unwrap()
    is SendDatagram(_, ping) else {
    fail("expected server ping")
  }
  assert_eq(client.on_datagram(client.endpoint(), ping, 3L).unwrap(), [])
  assert_eq(client.poll(4L).unwrap(), [])
  assert_eq(client.key_update.initial_send_packets, 1L)
  guard client.on_datagram(client.endpoint(), ack, 6L).unwrap()
    is [SendDatagram(_, deferred)] else {
    fail("expected one deferred client ACK")
  }
  assert_eq(deferred.length(), 1200)
  assert_eq(client.recovery.bytes_in_flight(), 1200L)
  guard server.on_datagram(server.endpoint(), deferred, 7L).unwrap()
    is [SendDatagram(_, final_ack)] else {
    fail("expected the deferred ACK plus PING to elicit feedback")
  }
  assert_eq(server.recovery.bytes_in_flight(), 0L)
  assert_eq(client.on_datagram(client.endpoint(), final_ack, 8L).unwrap(), [])
  assert_eq(client.recovery.bytes_in_flight(), 0L)
}

///|
test "a later cumulative ACK releases padding without acknowledging a packet gap" {
  let endpoint = @types.Endpoint::new("udp", "padding.example", 443).unwrap()
  let (client, server) = key_limit_driver_pair(endpoint, endpoint)
  for i in 0..<3 {
    guard client.send_frames(Application, [Padding], 0L).unwrap()
      is SendDatagram(_, packet) else {
      fail("expected padded application packet")
    }
    if i != 1 {
      assert_eq(server.on_datagram(endpoint, packet, 0L).unwrap(), [])
    }
  }
  let unit = client.recovery.bytes_in_flight() / 3L
  for expected in [unit, 0L] {
    guard client.send_frames(Application, [Ping], 0L).unwrap()
      is SendDatagram(_, packet) else {
      fail("expected ping")
    }
    guard server.on_datagram(endpoint, packet, 0L).unwrap()
      is [SendDatagram(_, ack)] else {
      fail("expected cumulative ACK")
    }
    ignore(client.on_datagram(endpoint, ack, 0L).unwrap())
    assert_eq(client.recovery.bytes_in_flight(), expected)
  }
}

///|
test "server Initial admission uses the enclosing UDP length and authenticates coalesced packets separately" {
  let (client, server) = retirement_security_pair()
  let dest = server.local_connection_id()
  let src = client.local_connection_id()
  let keys = quic_initial_packet_key(dest, Client).unwrap()
  let first = quic_build_long_packet(
    keys,
    0,
    QUIC_VERSION_1,
    dest,
    src,
    b"",
    0L,
    1,
    quic_encode_frames([Ping]).unwrap(),
  ).unwrap()
  let second = quic_build_long_packet(
    keys,
    0,
    QUIC_VERSION_1,
    dest,
    src,
    b"",
    1L,
    1,
    b"\x00",
    min_datagram_size=1200 - first.length(),
  ).unwrap()
  let datagram = quic_join_bytes([first, second])
  assert_eq(datagram.length(), 1200)
  assert_eq(server.on_datagram(server.endpoint(), first, 0L).unwrap(), [
    PacketIgnored,
  ])
  guard server.on_datagram(server.endpoint(), datagram, 1L).unwrap()
    is [SendDatagram(_, ack)] else {
    fail("expected one server ACK")
  }
  assert_true(ack.length() < 1200)
  assert_true(server.received_initial.seen(0L))
  assert_true(server.received_initial.seen(1L))
}
