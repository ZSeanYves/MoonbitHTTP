///|
fn key_limit_driver_pair(
  client_endpoint : @types.Endpoint,
  server_endpoint : @types.Endpoint,
  limits? : QuicLimits = QuicLimits::defaults(),
  recovery_config? : QuicRecoveryConfig = QuicRecoveryConfig::defaults(),
) -> (QuicDatagramDriver, QuicDatagramDriver) {
  let server_id = ConnectionId::new(b"server-id").unwrap()
  let client_id = ConnectionId::new(b"client-id").unwrap()
  let client = QuicDatagramDriver::new(
    Client,
    server_endpoint,
    server_id,
    client_id,
    server_id,
    limits~,
    recovery_config~,
  ).unwrap()
  let server = QuicDatagramDriver::new(
    Server,
    client_endpoint,
    server_id,
    server_id,
    client_id,
    limits~,
    recovery_config~,
  ).unwrap()
  let keys = quic_initial_packet_keys(server_id).unwrap()
  client.install_handshake_keys(keys.0, keys.1).unwrap()
  server.install_handshake_keys(keys.1, keys.0).unwrap()
  client.install_application_keys(keys.0, keys.1).unwrap()
  server.install_application_keys(keys.1, keys.0).unwrap()
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
  client.establish().unwrap()
  server.establish().unwrap()
  (client, server)
}

///|
test "quic key limits: stop before exhausting the confidentiality bound" {
  let endpoint = @types.Endpoint::new("udp", "key-limit.example", 443).unwrap()
  let (client, _) = key_limit_driver_pair(endpoint, endpoint)
  // Seed the accounting immediately below the RFC bound instead of exposing
  // configurable production limits or encrypting millions of fixture packets.
  client.key_update.send_packets = QUIC_AEAD_CONFIDENTIALITY_LIMIT - 1L
  ignore(client.send_frames(Application, [Ping], 0L).unwrap())
  assert_eq(client.key_update.send_packets, QUIC_AEAD_CONFIDENTIALITY_LIMIT)
  guard client.send_frames(Application, [Ping], 1L)
    is Err(Protocol(QUIC_AEAD_LIMIT_REACHED, _)) else {
    fail("expected AEAD_LIMIT_REACHED when a key cannot protect another packet")
  }
  assert_eq(client.state(), Closed)
  assert_eq(client.key_update.send_packets, QUIC_AEAD_CONFIDENTIALITY_LIMIT)
}

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

///|
test "quic key limits: encrypted packets consume budget when amplification blocks send" {
  let endpoint = @types.Endpoint::new("udp", "budget.example", 443).unwrap()
  let (_, server) = key_limit_driver_pair(endpoint, endpoint)
  server.active_budget.validated = false
  server.key_update.send_packets = QUIC_AEAD_CONFIDENTIALITY_LIMIT - 1L
  assert_true(
    server.send_frames(Application, [Ping], 0L) is Err(AmplificationBlocked),
  )
  assert_eq(server.key_update.send_packets, QUIC_AEAD_CONFIDENTIALITY_LIMIT)
  assert_eq(server.state(), Established)
  guard server.send_frames(Application, [Ping], 1L)
    is Err(Protocol(QUIC_AEAD_LIMIT_REACHED, _)) else {
    fail("expected exhausted keys to close after an unsent encryption")
  }
  assert_eq(server.state(), Closed)
}
