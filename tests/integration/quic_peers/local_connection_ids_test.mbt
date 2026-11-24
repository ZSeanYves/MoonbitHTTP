///|
test "lost local CID rotation preserves the old route until peer retirement" {
  let endpoint = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  let (client, server) = established_driver_pair(endpoint, endpoint)
  let initial = client.local_connection_id()
  let routes : Set[Bytes] = Set([initial.bytes()])
  let released = []
  client
  .enable_connection_id_issuance(
    @test_support.ZeroEntropy::new(),
    reserve=cid => {
      routes.add(cid.bytes())
      true
    },
    release=cid => {
      routes.remove(cid.bytes())
      released.push(cid)
    },
    max_issued=2,
  )
  .unwrap()
  // Lose the advertisement. An ACK for a later PING starts its loss timer.
  assert_eq(client.rotate_local_connection_id(0L).unwrap().length(), 1)
  assert_eq(client.rotate_local_connection_id(0L).unwrap(), [])
  guard client.send_frames(Application, [Ping], 0L).unwrap()
    is SendDatagram(_, ping) else {
    fail("expected PING")
  }
  guard server.on_datagram(endpoint, ping, 0L).unwrap()
    is [SendDatagram(_, ack)] else {
    fail("expected ACK")
  }
  guard server.send_frames(Application, [Ping], 1L).unwrap()
    is SendDatagram(_, delayed) else {
    fail("expected an old-route packet")
  }
  assert_eq(client.on_datagram(endpoint, ack, 80L).unwrap(), [])
  guard client.poll(90L).unwrap() is [SendDatagram(_, retry)] else {
    fail("expected a retransmitted announcement")
  }
  guard server.on_datagram(endpoint, retry, 91L).unwrap()
    is [SendDatagram(_, retire)] else {
    fail("expected a retirement on the replacement")
  }
  assert_eq(routes.length(), 2)
  assert_true(server.peer_connection_id() != initial)
  assert_true(routes.contains(server.peer_connection_id().bytes()))
  ignore(client.on_datagram(endpoint, retire, 92L).unwrap())
  assert_eq(released, [initial])
  assert_eq(routes.length(), 1)
  assert_eq(client.on_datagram(endpoint, delayed, 93L).unwrap(), [PacketIgnored])
  guard server.send_frames(Application, [RetireConnectionId(0L)], 94L).unwrap()
    is SendDatagram(_, duplicate) else {
    fail("expected duplicate retirement")
  }
  ignore(client.on_datagram(endpoint, duplicate, 95L).unwrap())
  assert_eq(released, [initial])
  assert_true(
    client.rotate_local_connection_id(96L) is Err(LimitExceeded(_, 2)),
  )
  let stream = client.connection().open_bidirectional_stream().unwrap()
  guard client.send_stream(stream, b"still usable", true, 97L).unwrap()
    is SendDatagram(_, data) else {
    fail("expected stream data")
  }
  assert_true(
    server
    .on_datagram(endpoint, data, 98L)
    .unwrap()
    .contains(StreamData(stream, b"still usable", true)),
  )
}

///|
struct CidEntropy {
  mut fills : Int32
}

///|
impl @transport.Entropy for CidEntropy with fn fill(self, buffer) {
  self.fills += 1
  for i in 0..<buffer.length() {
    buffer[i] = self.fills.to_byte()
  }
  Ok(())
}

///|
fn deliver_cid_packets(
  receiver : @quic.QuicDatagramDriver,
  source : @types.Endpoint,
  actions : Array[@quic.QuicDriverAction],
  now : Int64,
) -> Array[@quic.QuicDriverAction] {
  let output = []
  for action in actions {
    if action is SendDatagram(_, packet) {
      output.append(receiver.on_datagram(source, packet, now).unwrap())
    }
  }
  output
}

///|
test "blocked issuance rolls back routing, retains entropy and replenishes a retired ID" {
  let endpoint = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  let (client, server) = established_driver_pair(endpoint, endpoint, recovery_config={
    ..@quic.QuicRecoveryConfig::defaults(),
    max_tracked_packets: 1,
  })
  let entropy : CidEntropy = { fills: 0, }
  let routes : Set[Bytes] = Set([client.local_connection_id().bytes()])
  let mut collision = true
  client
  .enable_connection_id_issuance(
    entropy,
    reserve=cid => {
      if collision {
        collision = false
        return false
      }
      if routes.contains(cid.bytes()) {
        return false
      }
      routes.add(cid.bytes())
      true
    },
    release=cid => routes.remove(cid.bytes()),
    max_issued=3,
  )
  .unwrap()
  let stream = client.connection().open_bidirectional_stream().unwrap()
  guard client.send_stream(stream, b"first", true, 0L).unwrap()
    is SendDatagram(_, full) else {
    fail("expected tracked packet")
  }
  assert_eq(client.rotate_local_connection_id(0L).unwrap(), [])
  assert_eq(routes.length(), 1)
  assert_eq(entropy.fills, 4)
  assert_eq(client.poll(1L).unwrap(), [])
  assert_eq(entropy.fills, 4)
  let received = server.on_datagram(endpoint, full, 2L).unwrap()
  let announced = deliver_cid_packets(client, endpoint, received, 3L)
  assert_eq(routes.length(), 2)
  let retired = deliver_cid_packets(server, endpoint, announced, 4L)
  let replenished = deliver_cid_packets(client, endpoint, retired, 5L)
  assert_false(replenished.is_empty())
  assert_false(routes.contains(client.local_connection_id().bytes()))
  assert_true(routes.contains(server.peer_connection_id().bytes()))
  assert_eq(routes.length(), 2)
  assert_eq(entropy.fills, 6)
}

///|
test "peer may retire an unused spare and keep its selected destination" {
  let endpoint = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  let (client, server) = established_driver_pair(endpoint, endpoint)
  let initial = client.local_connection_id()
  let issued : Array[@quic.ConnectionId] = []
  let released : Array[@quic.ConnectionId] = []
  let entropy : CidEntropy = { fills: 0, }
  client
  .enable_connection_id_issuance(
    entropy,
    reserve=cid => {
      issued.push(cid)
      true
    },
    release=cid => released.push(cid),
    max_issued=3,
  )
  .unwrap()
  let announcement = client.poll(0L).unwrap()
  let replies = deliver_cid_packets(server, endpoint, announcement, 1L)
  ignore(deliver_cid_packets(client, endpoint, replies, 2L))
  assert_eq(server.peer_connection_id(), initial)
  let retire = server
    .send_frames(Application, [RetireConnectionId(1L)], 3L)
    .unwrap()
  let replenished = deliver_cid_packets(client, endpoint, [retire], 4L)
  assert_eq(issued.length(), 2)
  assert_true(issued[0] != issued[1])
  assert_eq(released, [issued[0]])
  let keys = @quic.quic_initial_packet_keys(server.local_connection_id()).unwrap()
  let mut replacement = false
  for action in replenished {
    if action is SendDatagram(_, packet) {
      let opened = @quic.quic_open_packet_with_keys(
        keys.0,
        packet,
        1 + server.local_connection_id().bytes().length(),
        -1L,
        false,
      ).unwrap()
      for frame in @quic.quic_decode_frames(opened.payload()).unwrap() {
        if frame is NewConnectionId(2L, 0L, id, _) {
          replacement = id == issued[1]
        }
      }
    }
  }
  assert_true(replacement)
}
