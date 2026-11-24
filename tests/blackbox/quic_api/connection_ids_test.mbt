///|
test "quic peer CID state starts at the authenticated server Initial identity" {
  let endpoint = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  let original = @quic.ConnectionId::new(b"original").unwrap()
  let local_id = @quic.ConnectionId::new(b"client").unwrap()
  let actual_peer = @quic.ConnectionId::new(b"actual-server").unwrap()
  let client = @quic.QuicDatagramDriver::new(
    Client,
    endpoint,
    original,
    local_id,
    original,
  ).unwrap()
  let initial_keys = @quic.quic_initial_packet_keys(original).unwrap()
  let incoming = @quic.quic_build_long_packet(
    initial_keys.1,
    0,
    1,
    local_id,
    actual_peer,
    b"",
    0L,
    1,
    @quic.quic_encode_frames([Ping]).unwrap(),
    min_datagram_size=1200,
  ).unwrap()
  ignore(client.on_datagram(endpoint, incoming, 1L).unwrap())
  client.install_handshake_keys(initial_keys.0, initial_keys.1).unwrap()
  client.install_application_keys(initial_keys.0, initial_keys.1).unwrap()
  client
  .set_peer_transport_parameters(
    @quic.QuicTransportParameters::new(
      actual_peer,
      original_destination_connection_id=Some(original),
    ),
  )
  .unwrap()
  client.establish().unwrap()
  assert_eq(client.peer_connection_id(), actual_peer)
  // The same CID under a different sequence is rejected only if the manager
  // was seeded with the authenticated identity, rather than original DCID.
  let payload = @quic.quic_encode_frames([
    NewConnectionId(
      1L,
      0L,
      actual_peer,
      Bytes::from_array(FixedArray::make(16, b'\x01')),
    ),
  ]).unwrap()
  let packet = @quic.quic_build_short_packet(
    initial_keys.1,
    local_id,
    0L,
    1,
    payload,
  ).unwrap()
  assert_true(
    client.on_datagram(endpoint, packet, 2L) is Err(Protocol(0x0aL, _)),
  )
  assert_eq(client.peer_connection_id(), actual_peer)
}
