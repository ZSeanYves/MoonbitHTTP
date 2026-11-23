///|
fn retirement_security_pair(
  recovery_config~ : QuicRecoveryConfig = QuicRecoveryConfig::defaults(),
) -> (QuicDatagramDriver, QuicDatagramDriver) {
  let endpoint = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  let server_id = ConnectionId::new(b"serverid").unwrap()
  let client_id = ConnectionId::new(b"clientid").unwrap()
  let client = QuicDatagramDriver::new(
    Client,
    endpoint,
    server_id,
    client_id,
    server_id,
    recovery_config~,
  ).unwrap()
  let server = QuicDatagramDriver::new(
    Server,
    endpoint,
    server_id,
    server_id,
    client_id,
    recovery_config~,
  ).unwrap()
  let hs_client = @tls.derive_quic_packet_keys(
    Bytes::from_array(FixedArray::make(32, b'h')),
  ).unwrap()
  let hs_server = @tls.derive_quic_packet_keys(
    Bytes::from_array(FixedArray::make(32, b'H')),
  ).unwrap()
  let app_client = @tls.derive_quic_packet_keys(
    Bytes::from_array(FixedArray::make(32, b'a')),
  ).unwrap()
  let app_server = @tls.derive_quic_packet_keys(
    Bytes::from_array(FixedArray::make(32, b'A')),
  ).unwrap()
  client.install_handshake_keys(hs_client, hs_server).unwrap()
  server.install_handshake_keys(hs_server, hs_client).unwrap()
  client.install_application_keys(app_client, app_server).unwrap()
  server.install_application_keys(app_server, app_client).unwrap()
  client
  .set_peer_transport_parameters(
    QuicTransportParameters::new(
      server_id,
      original_destination_connection_id=Some(server_id),
    ),
  )
  .unwrap()
  server
  .set_peer_transport_parameters(QuicTransportParameters::new(client_id))
  .unwrap()
  (client, server)
}

///|
fn retirement_security_server_packet(
  destination : ConnectionId,
  number : Int64,
  frames : Array[QuicFrame],
) -> Bytes {
  let keys = quic_initial_packet_keys(ConnectionId::new(b"server-id").unwrap()).unwrap()
  quic_build_short_packet(
    keys.1,
    destination,
    number,
    1,
    quic_encode_frames(frames).unwrap(),
  ).unwrap()
}

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
test "quic padding arithmetic handles every Length width without allocating payloads" {
  for
    (prefix, minimum, maximum, expected) in [
      (24, 89, 90, 44),
      (24, 16410, 16412, 16364),
      (24, 1073741851, 1073741856, 1073741803),
    ] {
    assert_eq(
      quic_builder_padding(prefix, 0, 4, minimum, maximum),
      Ok(expected),
    )
  }
  assert_true(quic_builder_padding(24, 0, 4, 89, 89) is Err(_))
  assert_true(quic_builder_padding(24, 0x7fffffff, 4, 0, 0x7fffffff) is Err(_))
}

///|
test "quic CID retirement with zero frame budget stays pending" {
  let endpoint = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  let limits = { ..QuicLimits::defaults(), max_frame_payload: 0, }
  let (client, _) = key_limit_driver_pair(endpoint, endpoint, limits~)
  client.pending_retirements.push(0L)
  assert_eq(client.poll(1L), Ok([]))
  assert_eq(client.pending_retirements, [0L])
}

///|
test "quic CID retirement waits for retransmission queue capacity" {
  let endpoint = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  let recovery_config = {
    ..QuicRecoveryConfig::defaults(),
    max_tracked_packets: 1,
  }
  let (client, _) = key_limit_driver_pair(endpoint, endpoint, recovery_config~)
  ignore(client.send_frames(Application, [MaxData(1048576L)], 0L).unwrap())
  client.pending_retirements.push(0L)
  assert_eq(client.poll(1L), Ok([]))
  assert_eq(client.pending_retirements, [0L])
}

///|
test "quic CID retirement waits for recovery queue capacity" {
  let endpoint = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  let recovery_config = {
    ..QuicRecoveryConfig::defaults(),
    max_tracked_packets: 1,
  }
  let (client, _) = key_limit_driver_pair(endpoint, endpoint, recovery_config~)
  ignore(
    client.send_frames(Application, [PathResponse(b"12345678")], 0L).unwrap(),
  )
  client.pending_retirements.push(0L)
  assert_eq(client.poll(1L), Ok([]))
  assert_eq(client.pending_retirements, [0L])
}

///|
test "quic received CID retirement preserves ACKs through queue saturation" {
  let endpoint = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  let recovery_config = {
    ..QuicRecoveryConfig::defaults(),
    max_tracked_packets: 1,
  }
  // MAX_DATA fills both queues; PING fills recovery without retaining a
  // retransmission. Both cases must accept and ACK the authenticated CID update.
  let outstanding_frames : Array[(QuicFrame, Int32)] = [
    (MaxData(1048576L), 1),
    (Ping, 0),
  ]
  for (outstanding, retained) in outstanding_frames {
    let (client, _) = key_limit_driver_pair(
      endpoint,
      endpoint,
      recovery_config~,
    )
    let keys = quic_initial_packet_keys(
      ConnectionId::new(b"server-id").unwrap(),
    ).unwrap()
    let peer_packet = fn(number : Int64, frames : Array[QuicFrame]) {
      quic_build_short_packet(
        keys.1,
        client.local_connection_id(),
        number,
        1,
        quic_encode_frames(frames).unwrap(),
      ).unwrap()
    }
    ignore(client.send_frames(Application, [outstanding], 0L).unwrap())
    let replacement = ConnectionId::new(b"replacement").unwrap()
    let announcement = peer_packet(0L, [
      NewConnectionId(
        1L,
        1L,
        replacement,
        Bytes::from_array(FixedArray::make(16, b'\x01')),
      ),
    ])
    guard client.on_datagram(endpoint, announcement, 1L).unwrap()
      is [SendDatagram(_, reply)] else {
      fail("expected an ACK while CID retirement queues are full")
    }
    let ack_reply = quic_open_packet_with_keys(
      keys.0,
      reply,
      1 + replacement.bytes().length(),
      0L,
      false,
    ).unwrap()
    let reply_frames = quic_decode_frames(ack_reply.payload()).unwrap()
    assert_true(
      reply_frames.any(fn(frame) {
        match frame {
          Ack(ack) => ack.largest_acknowledged() == 0L
          _ => false
        }
      }),
    )
    assert_true(
      reply_frames.all(fn(frame) {
        match frame {
          Ack(_) | Padding => true
          _ => false
        }
      }),
    )
    assert_eq(client.state(), Established)
    assert_eq(client.peer_connection_id(), replacement)
    assert_eq(client.pending_retirements, [0L])
    assert_eq(client.retransmissions.length(), retained)
    assert_eq(client.recovery.sent.length(), 1)

    // A wire ACK releases the original packet's capacity. The receive path
    // emits the deferred retirement exactly once and transfers it to recovery.
    let release = peer_packet(1L, [
      Ack(AckFrame::new(0L, 0L, [AckRange::new(0L, 0L).unwrap()]).unwrap()),
    ])
    guard client.on_datagram(endpoint, release, 2L).unwrap()
      is [SendDatagram(_, retirement)] else {
      fail("expected one deferred CID retirement after queue capacity returns")
    }
    let opened = quic_open_packet_with_keys(
      keys.0,
      retirement,
      1 + replacement.bytes().length(),
      ack_reply.packet_number(),
      false,
    ).unwrap()
    assert_eq(
      quic_decode_frames(opened.payload())
      .unwrap()
      .filter(fn(frame) { frame != Padding }),
      [RetireConnectionId(0L)],
    )
    assert_true(client.pending_retirements.is_empty())
    assert_eq(client.retransmissions.length(), 1)
    assert_eq(client.retransmissions[0].frames, [RetireConnectionId(0L)])
    assert_eq(client.recovery.sent.length(), 1)
    assert_eq(client.on_datagram(endpoint, release, 3L), Ok([PacketIgnored]))
    assert_eq(client.poll(3L), Ok([]))

    let retired_number = opened.packet_number()
    let retirement_ack = peer_packet(2L, [
      Ack(
        AckFrame::new(retired_number, 0L, [
          AckRange::new(retired_number, retired_number).unwrap(),
        ]).unwrap(),
      ),
    ])
    assert_eq(client.on_datagram(endpoint, retirement_ack, 4L), Ok([]))
    assert_true(client.retransmissions.is_empty())
    assert_true(client.recovery.sent.is_empty())
    assert_eq(client.poll(5L), Ok([]))
  }
}

///|
test "quic mixed CID path challenge defers packet until response capacity returns" {
  let endpoint = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  let recovery_config = {
    ..QuicRecoveryConfig::defaults(),
    max_tracked_packets: 1,
  }
  let (client, _) = key_limit_driver_pair(endpoint, endpoint, recovery_config~)
  let original_peer = client.peer_connection_id()
  ignore(
    client.send_frames(Application, [PathResponse(b"occupied")], 0L).unwrap(),
  )
  let replacement = ConnectionId::new(b"replacement").unwrap()
  let packet = retirement_security_server_packet(
    client.local_connection_id(),
    0L,
    [
      NewConnectionId(
        1L,
        1L,
        replacement,
        Bytes::from_array(FixedArray::make(16, b'\x01')),
      ),
      PathChallenge(b"12345678"),
      Stream(StreamFrame::new(1L, 0L, b"deferred", true).unwrap()),
    ],
  )
  assert_eq(client.on_datagram(endpoint, packet, 1L), Ok([PacketIgnored]))
  assert_eq(client.peer_connection_id(), original_peer)
  assert_eq(client.peer_connection_ids.retire_prior_to, 0L)
  assert_true(client.pending_retirements.is_empty())
  assert_false(client.received_application.seen(0L))
  assert_false(client.connection.streams.contains(1L))
  assert_eq(client.recovery.sent.length(), 1)

  let release = retirement_security_server_packet(
    client.local_connection_id(),
    1L,
    [Ack(AckFrame::new(0L, 0L, [AckRange::new(0L, 0L).unwrap()]).unwrap())],
  )
  assert_eq(client.on_datagram(endpoint, release, 2L), Ok([]))
  assert_true(client.recovery.sent.is_empty())
  let actions = client.on_datagram(endpoint, packet, 3L).unwrap()
  guard actions is [StreamData(1L, b"deferred", true), SendDatagram(_, reply)] else {
    fail("expected deferred stream delivery and one path/CID response")
  }
  let keys = quic_initial_packet_keys(ConnectionId::new(b"server-id").unwrap()).unwrap()
  let opened = quic_open_packet_with_keys(
    keys.0,
    reply,
    1 + replacement.bytes().length(),
    0L,
    false,
  ).unwrap()
  let reply_frames = quic_decode_frames(opened.payload()).unwrap()
  assert_true(reply_frames.contains(PathResponse(b"12345678")))
  assert_true(reply_frames.contains(RetireConnectionId(0L)))
  assert_eq(client.peer_connection_id(), replacement)
  assert_true(client.pending_retirements.is_empty())
  assert_true(client.received_application.seen(0L))
  assert_eq(client.on_datagram(endpoint, packet, 4L), Ok([PacketIgnored]))
  assert_eq(client.poll(4L), Ok([]))
}

///|
test "quic mixed CID path challenge applies same packet ACK before admission" {
  let endpoint = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  let recovery_config = {
    ..QuicRecoveryConfig::defaults(),
    max_tracked_packets: 1,
  }
  let (client, _) = key_limit_driver_pair(endpoint, endpoint, recovery_config~)
  ignore(client.send_frames(Application, [Ping], 0L).unwrap())
  let replacement = ConnectionId::new(b"replacement").unwrap()
  // The ACK deliberately follows the frames that need response capacity.
  let packet = retirement_security_server_packet(
    client.local_connection_id(),
    0L,
    [
      NewConnectionId(
        1L,
        1L,
        replacement,
        Bytes::from_array(FixedArray::make(16, b'\x01')),
      ),
      PathChallenge(b"12345678"),
      Stream(StreamFrame::new(1L, 0L, b"accepted", true).unwrap()),
      Ack(AckFrame::new(0L, 0L, [AckRange::new(0L, 0L).unwrap()]).unwrap()),
    ],
  )
  guard client.on_datagram(endpoint, packet, 1L).unwrap()
    is [StreamData(1L, b"accepted", true), SendDatagram(_, reply)] else {
    fail("same-packet ACK should release capacity before path/CID admission")
  }
  let keys = quic_initial_packet_keys(ConnectionId::new(b"server-id").unwrap()).unwrap()
  let opened = quic_open_packet_with_keys(
    keys.0,
    reply,
    1 + replacement.bytes().length(),
    0L,
    false,
  ).unwrap()
  let reply_frames = quic_decode_frames(opened.payload()).unwrap()
  assert_true(reply_frames.contains(PathResponse(b"12345678")))
  assert_true(reply_frames.contains(RetireConnectionId(0L)))
  assert_eq(client.peer_connection_id(), replacement)
  assert_true(client.pending_retirements.is_empty())
  assert_eq(client.recovery.sent.length(), 1)
  assert_eq(client.retransmissions.length(), 1)
  assert_eq(client.retransmissions[0].frames, [RetireConnectionId(0L)])
  assert_eq(client.on_datagram(endpoint, packet, 2L), Ok([PacketIgnored]))
  assert_eq(client.poll(2L), Ok([]))
}

///|
test "quic mixed CID path response survives a blocked retransmission refill" {
  let endpoint = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  let recovery_config = {
    ..QuicRecoveryConfig::defaults(),
    max_tracked_packets: 2,
  }
  let (client, _) = key_limit_driver_pair(endpoint, endpoint, recovery_config~)
  // Keep one tracked packet and make its retained frames eligible for a
  // replacement.  The incoming packet below needs the final recovery slot
  // for PATH_RESPONSE and the CID retirement it schedules.
  ignore(client.send_frames(Application, [MaxData(1048576L)], 0L).unwrap())
  assert_eq(client.recovery.sent.length(), 1)
  assert_eq(client.retransmissions.length(), 1)
  client.note_retransmission_loss(Application, 0L)
  let replacement = ConnectionId::new(b"replacement").unwrap()
  let packet = retirement_security_server_packet(
    client.local_connection_id(),
    0L,
    [
      NewConnectionId(
        1L,
        1L,
        replacement,
        Bytes::from_array(FixedArray::make(16, b'\x01')),
      ),
      PathChallenge(b"12345678"),
    ],
  )
  guard client.on_datagram(endpoint, packet, 1L).unwrap()
    is [SendDatagram(_, reply)] else {
    fail("expected CID/path response despite blocked retransmission refill")
  }
  let keys = quic_initial_packet_keys(ConnectionId::new(b"server-id").unwrap()).unwrap()
  let opened = quic_open_packet_with_keys(
    keys.0,
    reply,
    1 + replacement.bytes().length(),
    0L,
    false,
  ).unwrap()
  let reply_frames = quic_decode_frames(opened.payload()).unwrap()
  assert_true(reply_frames.contains(PathResponse(b"12345678")))
  assert_true(
    reply_frames.contains(
      Ack(AckFrame::new(0L, 0L, [AckRange::new(0L, 0L).unwrap()]).unwrap()),
    ),
  )
  assert_true(reply_frames.contains(RetireConnectionId(0L)))
  assert_eq(client.peer_connection_id(), replacement)
  assert_true(client.pending_retirements.is_empty())
  // The old loss is still pending; the response was returned instead of being
  // discarded behind a recovery-queue LimitExceeded error.
  assert_eq(client.recovery.sent.length(), 2)
  assert_eq(client.retransmissions.length(), 2)
  assert_true(client.retransmissions.any(fn(entry) { entry.live.is_empty() }))
  assert_true(client.received_application.seen(0L))
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

///|
test "bounded ACK ranges retain an old trigger, merge adjacent intervals and clip the receive window" {
  let history = QuicReceivedPackets::new()
  for i in 0L..<32L {
    history.record(i * 2L, i)
  }
  history.record(1L, 50L)
  history.pending = Some((1L, 50L))
  assert_eq(history.ranges.last(), Some({ largest: 2L, smallest: 0L, }))
  for extra in [0, 1, 256] {
    let limits = { ..QuicLimits::defaults(), max_ack_ranges: extra, }
    guard history.pending_ack(Application, limits, 60L) is Some(Ack(ack)) else {
      fail("expected ACK")
    }
    assert_true(ack.covers(1L))
    assert_false(ack.covers(3L))
    assert_eq(ack.ranges.length(), (extra + 1).min(16))
    assert_eq(ack.ack_delay, if extra == 0 { 1250L } else { 3625L })
    assert_true(quic_encode_frame(Ack(ack), limits~) is Ok(_))
  }
  history.record(4096L, 100L)
  assert_true(history.seen(0L))
  assert_false(history.seen(3L))
  assert_eq(history.ranges.last(), Some({ largest: 2L, smallest: 1L, }))
}
