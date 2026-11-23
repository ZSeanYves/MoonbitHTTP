///|
test "authenticated stateless reset enters draining and suppresses future output" {
  let peer = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  let token = b"test token bytes"
  let (client, _) = established_driver_pair(
    peer,
    peer,
    server_reset_token=Some(token),
  )
  let datagram = b"\xc0test" + token
  assert_eq(client.receive_stateless_reset(peer, datagram), None)
  ignore(client.send_frames(Application, [Ping], 1L).unwrap())
  let other = @types.Endpoint::new("udp", "peer.test", 9443).unwrap()
  assert_eq(client.receive_stateless_reset(other, datagram), None)
  assert_eq(client.receive_stateless_reset(peer, datagram[1:]), None)
  assert_eq(
    client.receive_stateless_reset(peer, b"\xc0testtest token byte!"),
    None,
  )
  // Reset detection uses the whole datagram before attempting to parse its
  // header. This also covers a long header that cannot name a connection.
  assert_eq(
    client.on_datagram(peer, datagram, 2L),
    Ok([ConnectionClosed(0L, "QUIC stateless reset")]),
  )
  assert_eq(client.connection().peer_close(), Some(StatelessReset))
  assert_eq(client.state(), Draining)
  assert_eq(client.poll(10000L), Ok([]))
  assert_eq(client.on_datagram(peer, datagram, 3L), Ok([PacketIgnored]))
  assert_true(
    client.send_frames(Application, [Ping], 4L) is Err(ConnectionClosed(_, _)),
  )
}

///|
test "reset eligibility follows CID retirement and the actual probe destination" {
  let peer = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  let other = @types.Endpoint::new("udp", "peer.test", 9443).unwrap()
  let initial = b"test token bytes"
  let (client, server) = established_driver_pair(
    peer,
    peer,
    server_reset_token=Some(initial),
  )
  let entropy : CidEntropy = { fills: 0, }
  server.enable_connection_id_issuance(entropy).unwrap()
  let spare = b"other" + Bytes::make(16, b'\x02')
  let replies = deliver_cid_packets(client, peer, server.poll(1L).unwrap(), 2L)
  ignore(deliver_cid_packets(server, peer, replies, 3L))
  assert_eq(client.receive_stateless_reset(peer, spare), None)
  let announcement = server.rotate_local_connection_id(4L).unwrap()
  let retire = deliver_cid_packets(client, peer, announcement, 5L)
  assert_false(retire.is_empty())
  assert_eq(client.receive_stateless_reset(peer, b"first" + initial), None)
  assert_eq(client.receive_stateless_reset(other, spare), None)
  ignore(client.begin_path_validation(other, b"12345678", 6L).unwrap())
  assert_true(
    client.receive_stateless_reset(other, spare) is Some(ConnectionClosed(_, _)),
  )
}
