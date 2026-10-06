///|
fn retirement_security_pair() -> (QuicDatagramDriver, QuicDatagramDriver) {
  let endpoint = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  let server_id = ConnectionId::new(b"serverid").unwrap()
  let client_id = ConnectionId::new(b"clientid").unwrap()
  let client = QuicDatagramDriver::new(
    Client,
    endpoint,
    server_id,
    client_id,
    server_id,
  ).unwrap()
  let server = QuicDatagramDriver::new(
    Server,
    endpoint,
    server_id,
    server_id,
    client_id,
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
  ignore(client.send_frames(Application, [Ping], 0L).unwrap())
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
  // Ping fills both queues; PATH_RESPONSE fills recovery without retaining a
  // retransmission. Both cases must accept and ACK the authenticated CID update.
  let outstanding_frames : Array[(QuicFrame, Int)] = [
    (Ping, 1),
    (PathResponse(b"12345678"), 0),
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
  assert_false(client.quic_driver_seen(Application, 0L))
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
  assert_true(client.quic_driver_seen(Application, 0L))
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
