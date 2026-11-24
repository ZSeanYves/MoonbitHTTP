///|
test "quic key limits: count authentication failures and close at the bound" {
  let endpoint = @types.Endpoint::new("udp", "integrity-limit.example", 443).unwrap()
  let (client, server) = key_limit_driver_pair(endpoint, endpoint)
  // Keep the authentication tag tail outside the header-protection sample,
  // so tampering must reach AEAD verification rather than corrupting parsing.
  guard client
    .send_frames(Application, [Ping, Padding, Padding, Padding], 0L)
    .unwrap()
    is SendDatagram(_, packet) else {
    fail("expected authenticated application packet")
  }
  let corrupted = packet.to_array()
  corrupted[corrupted.length() - 1] = corrupted[corrupted.length() - 1] ^ 1
  let invalid = Bytes::from_array(corrupted)
  assert_true(
    server.on_datagram(endpoint, invalid, 1L)
    is Err(Tls(PacketAuthenticationFailed)),
  )
  // Move to one failure below the RFC integrity bound, then verify the next
  // authentication failure closes the connection with transport code 0x0f.
  server.key_update.receive_failures = QUIC_AEAD_INTEGRITY_LIMIT - 1L
  guard server.on_datagram(endpoint, invalid, 2L)
    is Err(Protocol(QUIC_AEAD_LIMIT_REACHED, _)) else {
    fail("expected AEAD_LIMIT_REACHED at the authentication failure bound")
  }
  assert_eq(server.state(), Closed)
  assert_eq(server.key_update.receive_failures, QUIC_AEAD_INTEGRITY_LIMIT)
}

///|
test "quic key update: illegal authenticated phase closes the connection" {
  let endpoint = @types.Endpoint::new("udp", "phase.example", 443).unwrap()
  let (client, server) = key_limit_driver_pair(endpoint, endpoint)
  guard client.send_frames(Application, [Ping], 0L).unwrap()
    is SendDatagram(_, packet) else {
    fail("expected authenticated application packet")
  }
  // The packet is authenticated with the current keys but advertises the
  // phase the peer has not accepted. This is a connection protocol error.
  server.key_update.receive_phase = true
  guard server.on_datagram(endpoint, packet, 1L)
    is Err(Protocol(QUIC_KEY_UPDATE_ERROR, _)) else {
    fail("expected KEY_UPDATE_ERROR for an illegal phase")
  }
  assert_eq(server.state(), Closed)
}

///|
test "quic key limits: eligible application keys update at the send bound" {
  let endpoint = @types.Endpoint::new("udp", "rotate.example", 443).unwrap()
  let (client, server) = key_limit_driver_pair(endpoint, endpoint)
  guard client.send_frames(Application, [Ping], 0L).unwrap()
    is SendDatagram(_, first) else {
    fail("expected initial application packet")
  }
  guard server.on_datagram(endpoint, first, 1L).unwrap()
    is [SendDatagram(_, ack)] else {
    fail("expected peer acknowledgment")
  }
  ignore(client.on_datagram(endpoint, ack, 2L).unwrap())
  assert_true(client.handshake_confirmed())
  client.key_update.send_packets = QUIC_AEAD_CONFIDENTIALITY_LIMIT
  guard client.send_frames(Application, [Ping], 3L).unwrap()
    is SendDatagram(_, updated) else {
    fail("expected packet protected by the next key generation")
  }
  assert_eq(client.key_update.send_generation, 1)
  assert_eq(client.key_update.send_packets, 1L)
  assert_eq(client.state(), Established)
  assert_true(server.on_datagram(endpoint, updated, 4L) is Ok(_))
}
