///|
fn key_limit_driver_pair(
  client_endpoint : @types.Endpoint,
  server_endpoint : @types.Endpoint,
  limits~ : QuicLimits = QuicLimits::defaults(),
  recovery_config~ : QuicRecoveryConfig = QuicRecoveryConfig::defaults(),
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
      limits=server.connection().local_transport_params(),
    ),
  )
  .unwrap()
  server
  .set_peer_transport_parameters(
    QuicTransportParameters::new(
      client_id,
      limits=client.connection().local_transport_params(),
    ),
  )
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
test "quic key limits: amplification backpressure preserves the last available encryption" {
  let endpoint = @types.Endpoint::new("udp", "budget.example", 443).unwrap()
  let (_, server) = key_limit_driver_pair(endpoint, endpoint)
  server.active_budget.validated = false
  server.key_update.send_packets = QUIC_AEAD_CONFIDENTIALITY_LIMIT - 1L
  assert_true(
    server.send_frames(Application, [Ping], 0L) is Err(AmplificationBlocked),
  )
  assert_eq(
    server.key_update.send_packets,
    QUIC_AEAD_CONFIDENTIALITY_LIMIT - 1L,
  )
  assert_eq(server.next_application_packet, 0L)
  server.active_budget.validated = true
  ignore(server.send_frames(Application, [Ping], 1L).unwrap())
  assert_eq(server.key_update.send_packets, QUIC_AEAD_CONFIDENTIALITY_LIMIT)
  guard server.send_frames(Application, [Ping], 2L)
    is Err(Protocol(QUIC_AEAD_LIMIT_REACHED, _)) else {
    fail("expected exhausted unconfirmed keys to close")
  }
  assert_eq(server.state(), Closed)
}
