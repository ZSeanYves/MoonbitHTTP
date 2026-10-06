///|
test "quic CID retirement survives congestion and pending limits are atomic" {
  let endpoint = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  let (_, server) = key_limit_driver_pair(endpoint, endpoint)
  let original = ConnectionId::new(b"server-id").unwrap()
  let keys = quic_initial_packet_keys(original).unwrap()
  let replacement = ConnectionId::new(b"replacement").unwrap()
  server.recovery.bytes_in_flight = server.recovery.congestion_window
  let packet = quic_build_short_packet(
    keys.0,
    server.local_connection_id(),
    0L,
    1,
    quic_encode_frames([
      NewConnectionId(
        1L,
        1L,
        replacement,
        Bytes::from_array(FixedArray::make(16, b'\x01')),
      ),
    ]).unwrap(),
  ).unwrap()
  let blocked = server.on_datagram(endpoint, packet, 1L).unwrap()
  assert_false(blocked.any(fn(action) { action is SendDatagram(_, _) }))
  assert_eq(server.peer_connection_id(), replacement)
  assert_eq(server.pending_retirements, [0L])
  server.recovery.bytes_in_flight = 0L
  let sent = server.poll(2L).unwrap()
  assert_true(server.pending_retirements.is_empty())
  assert_true(sent.any(fn(action) { action is SendDatagram(_, _) }))
  assert_true(
    server.retransmissions.any(fn(entry) {
      entry.frames.contains(RetireConnectionId(0L))
    }),
  )
  // Saturate only the bounded control queue to test rejection without issuing
  // thousands of encrypted packets. The rejected announcement must not change
  // its floor, active IDs, or destination.
  for sequence in 0..<server.max_retransmissions {
    server.pending_retirements.push(sequence.to_int64() + 100L)
  }
  let previous_ids = server.peer_connection_ids.active()
  assert_true(
    server.receive_peer_connection_id(
      2L,
      2L,
      ConnectionId::new(b"later").unwrap(),
      Bytes::from_array(FixedArray::make(16, b'\x02')),
    )
    is Err(LimitExceeded("pending CID retirements", _)),
  )
  assert_eq(server.peer_connection_ids.active(), previous_ids)
  assert_eq(server.peer_connection_ids.retire_prior_to, 1L)
  assert_eq(server.peer_connection_id(), replacement)
}

///|
test "quic CID retirement stays pending across delayed Handshake packets" {
  let endpoint = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  let (client, _) = key_limit_driver_pair(endpoint, endpoint)
  let original = ConnectionId::new(b"server-id").unwrap()
  let keys = quic_initial_packet_keys(original).unwrap()
  let replacement = ConnectionId::new(b"replacement").unwrap()
  client.recovery.bytes_in_flight = client.recovery.congestion_window
  let announcement = quic_build_short_packet(
    keys.1,
    client.local_connection_id(),
    0L,
    1,
    quic_encode_frames([
      NewConnectionId(
        1L,
        1L,
        replacement,
        Bytes::from_array(FixedArray::make(16, b'\x01')),
      ),
    ]).unwrap(),
  ).unwrap()
  ignore(client.on_datagram(endpoint, announcement, 1L).unwrap())
  assert_eq(client.pending_retirements, [0L])
  assert_false(client.key_update.confirmed)
  // TLS is complete, but HANDSHAKE_DONE has not arrived. A reordered packet
  // still needs a Handshake ACK without application-only retirement frames.
  // A one-byte packet number needs at least three plaintext bytes for the
  // header-protection sample; padding keeps the packet a Handshake Ping.
  let delayed = match
    quic_build_long_packet(
      keys.1,
      2,
      QUIC_VERSION_1,
      client.local_connection_id(),
      original,
      b"",
      0L,
      1,
      quic_encode_frames([Ping, Padding, Padding, Padding]).unwrap(),
    ) {
    Ok(packet) => packet
    Err(error) => fail("building delayed Handshake packet: \{Repr(error)}")
  }
  let replies = match client.on_datagram(endpoint, delayed, 2L) {
    Ok(actions) => actions
    Err(error) => fail("receiving delayed Handshake packet: \{Repr(error)}")
  }
  assert_true(replies.any(fn(action) { action is SendDatagram(_, _) }))
  assert_eq(client.pending_retirements, [0L])
  assert_eq(client.peer_connection_id(), replacement)
  assert_false(
    client.retransmissions.any(fn(entry) {
      entry.space == Handshake && entry.frames.contains(RetireConnectionId(0L))
    }),
  )
  client.recovery.bytes_in_flight = 0L
  match client.poll(3L) {
    Ok(_) => ()
    Err(error) => fail("flushing delayed CID retirement: \{Repr(error)}")
  }
  assert_true(client.pending_retirements.is_empty())
  assert_true(
    client.retransmissions.any(fn(entry) {
      entry.space == Application &&
      entry.frames.contains(RetireConnectionId(0L))
    }),
  )
}

///|
test "quic CID retirements leave room for existing path responses" {
  let endpoint = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  let (_, server) = key_limit_driver_pair(endpoint, endpoint)
  let original = ConnectionId::new(b"server-id").unwrap()
  let keys = quic_initial_packet_keys(original).unwrap()
  // Build a valid retirement backlog without needing 64 encrypted packets.
  for sequence in 1L..<65L {
    server
    .receive_peer_connection_id(
      sequence,
      sequence,
      ConnectionId::new(@utf8.encode("cid-\{sequence}")).unwrap(),
      Bytes::from_array(FixedArray::make(16, b'\x01')),
    )
    .unwrap()
  }
  assert_eq(server.pending_retirements.length(), 64)
  let frames : Array[QuicFrame] = []
  for _ in 0..<130 {
    frames.push(PathChallenge(b"12345678"))
  }
  let packet = match
    quic_build_short_packet(
      keys.0,
      server.local_connection_id(),
      0L,
      1,
      quic_encode_frames(frames).unwrap(),
    ) {
    Ok(packet) => packet
    Err(error) => fail("building near-MTU path challenge: \{Repr(error)}")
  }
  assert_true(packet.length() <= server.send_datagram_limit())
  let replies = match server.on_datagram(endpoint, packet, 1L) {
    Ok(actions) => actions
    Err(error) => fail("receiving near-MTU path challenge: \{Repr(error)}")
  }
  assert_true(replies.any(fn(action) { action is SendDatagram(_, _) }))
  for action in replies {
    if action is SendDatagram(_, response) {
      assert_true(response.length() <= server.send_datagram_limit())
    }
  }
  assert_eq(server.pending_retirements.length(), 64)
  match server.poll(2L) {
    Ok(_) => ()
    Err(error) => fail("flushing CID retirement backlog: \{Repr(error)}")
  }
  assert_true(server.pending_retirements.is_empty())
  assert_true(
    server.retransmissions.any(fn(entry) {
      entry.frames.contains(RetireConnectionId(0L)) &&
      entry.frames.contains(RetireConnectionId(63L))
    }),
  )
}
