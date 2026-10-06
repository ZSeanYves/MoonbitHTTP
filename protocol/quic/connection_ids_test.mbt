///|
fn cid_test_packet(
  destination : @quic.ConnectionId,
  number : Int64,
  frames : Array[@quic.QuicFrame],
) -> Bytes {
  let original = @quic.ConnectionId::new(b"server-id").unwrap()
  let keys = @quic.quic_initial_packet_keys(original).unwrap()
  @quic.quic_build_short_packet(
    keys.0,
    destination,
    number,
    2,
    @quic.quic_encode_frames(frames).unwrap(),
  ).unwrap()
}

///|
test "quic CID directions: a peer cannot retire IDs it just announced" {
  let endpoint = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  let (_, server) = established_driver_pair(endpoint, endpoint)
  let local_id = server.local_connection_id()
  let original_peer = server.peer_connection_id()
  let announced = @quic.ConnectionId::new(b"announced").unwrap()
  let token = Bytes::from_array(FixedArray::make(16, b'\x01'))
  // Reject the entire NEW/RETIRE packet before the NEW can change state.
  for sequence in 1L..<100L {
    let packet = cid_test_packet(local_id, sequence, [
      NewConnectionId(sequence, sequence, announced, token),
      RetireConnectionId(sequence),
    ])
    assert_true(
      server.on_datagram(endpoint, packet, sequence) is Err(Protocol(0x0aL, _)),
    )
    assert_eq(server.peer_connection_id(), original_peer)
  }
  let retire_initial = cid_test_packet(local_id, 101L, [RetireConnectionId(0L)])
  assert_true(
    server.on_datagram(endpoint, retire_initial, 101L)
    is Err(Protocol(0x0aL, _)),
  )
  let valid = cid_test_packet(local_id, 102L, [Ping])
  assert_true(server.on_datagram(endpoint, valid, 102L) is Ok(_))
  assert_true(
    server.send_frames(
      Application,
      [NewConnectionId(1L, 0L, announced, token)],
      103L,
    )
    is Err(Unsupported(_)),
  )
}

///|
test "quic peer CID rotation: retire old IDs and send using the replacement" {
  let endpoint = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  let (_, server) = established_driver_pair(endpoint, endpoint)
  let local_id = server.local_connection_id()
  let original_peer = server.peer_connection_id()
  let replacement = @quic.ConnectionId::new(b"replacement").unwrap()
  let token = Bytes::from_array(FixedArray::make(16, b'\x01'))
  let original = @quic.ConnectionId::new(b"server-id").unwrap()
  let keys = @quic.quic_initial_packet_keys(original).unwrap()
  // Initially preserve the current destination when the old CID stays active.
  let first = cid_test_packet(local_id, 0L, [
    NewConnectionId(1L, 0L, replacement, token),
  ])
  ignore(server.on_datagram(endpoint, first, 1L).unwrap())
  assert_eq(server.peer_connection_id(), original_peer)
  // A duplicate announcement can advance the floor and retire sequence zero.
  let update = cid_test_packet(local_id, 1L, [
    NewConnectionId(1L, 1L, replacement, token),
  ])
  let actions = server.on_datagram(endpoint, update, 2L).unwrap()
  assert_eq(server.peer_connection_id(), replacement)
  let mut retired_initial = false
  for action in actions {
    if action is SendDatagram(_, packet) {
      assert_eq(
        packet[1:1 + replacement.bytes().length()].to_owned(),
        replacement.bytes(),
      )
      let opened = @quic.quic_open_packet_with_keys(
        keys.1,
        packet,
        1 + replacement.bytes().length(),
        -1L,
        false,
      ).unwrap()
      let frames = @quic.quic_decode_frames(opened.payload()).unwrap()
      retired_initial = retired_initial ||
        frames.contains(RetireConnectionId(0L))
    }
  }
  assert_true(retired_initial)
  // A reordered announcement never resurrects the retired destination.
  let stale = cid_test_packet(local_id, 2L, [
    NewConnectionId(
      0L,
      0L,
      original_peer,
      Bytes::from_array(FixedArray::make(16, b'\x02')),
    ),
  ])
  assert_true(server.on_datagram(endpoint, stale, 3L) is Ok(_))
  assert_eq(server.peer_connection_id(), replacement)
}

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
