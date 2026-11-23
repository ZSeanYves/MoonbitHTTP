///|
fn established_driver_pair(
  client_endpoint : @types.Endpoint,
  server_endpoint : @types.Endpoint,
  established~ : Bool = true,
  server_reset_token~ : Bytes? = None,
  recovery_config~ : @quic.QuicRecoveryConfig = @quic.QuicRecoveryConfig::defaults(),
) -> (@quic.QuicDatagramDriver, @quic.QuicDatagramDriver) {
  let server_id = @quic.ConnectionId::new(b"server-id").unwrap()
  let client_id = @quic.ConnectionId::new(b"client-id").unwrap()
  let client = @quic.QuicDatagramDriver::new(
    Client,
    server_endpoint,
    server_id,
    client_id,
    server_id,
    recovery_config~,
  ).unwrap()
  let server = @quic.QuicDatagramDriver::new(
    Server,
    client_endpoint,
    server_id,
    server_id,
    client_id,
  ).unwrap()
  // Deterministic fixture keys exercise the driver without claiming to run
  // a TLS handshake. Real traffic secrets are a separate production gate.
  let keys = @quic.quic_initial_packet_keys(server_id).unwrap()
  client.install_handshake_keys(keys.0, keys.1).unwrap()
  server.install_handshake_keys(keys.1, keys.0).unwrap()
  client.install_application_keys(keys.0, keys.1).unwrap()
  server.install_application_keys(keys.1, keys.0).unwrap()
  client
  .set_peer_transport_parameters({
    ..@quic.QuicTransportParameters::new(
      server_id,
      original_destination_connection_id=Some(server_id),
    ),
    stateless_reset_token: server_reset_token,
  })
  .unwrap()
  server
  .set_peer_transport_parameters(@quic.QuicTransportParameters::new(client_id))
  .unwrap()
  if established {
    client.establish().unwrap()
    server.establish().unwrap()
  }
  (client, server)
}

///|
test "quic driver state: Initial and Handshake reject application frames before effects" {
  let client_endpoint = @types.Endpoint::new("udp", "client.test", 443).unwrap()
  let server_endpoint = @types.Endpoint::new("udp", "server.test", 443).unwrap()
  let server_id = @quic.ConnectionId::new(b"server-id").unwrap()
  let client_id = @quic.ConnectionId::new(b"client-id").unwrap()
  let keys = @quic.quic_initial_packet_keys(server_id).unwrap()
  let stream = @quic.StreamFrame::new(0L, 0L, b"unsafe", true).unwrap()
  for
    (space, packet_type) in [
      (@quic.PacketNumberSpace::Initial, 0),
      (Handshake, 2),
    ] {
    let (client, server) = established_driver_pair(
      client_endpoint,
      server_endpoint,
      established=false,
    )
    for
      frame in [
        @quic.QuicFrame::Stream(stream),
        MaxData(99L),
        PathChallenge(b"12345678"),
        ConnectionClose(false, 0L, 0L, b""),
      ] {
      assert_true(
        client.send_frames(space, [frame], 0L) is Err(InvalidFrame(_)),
      )
    }
    // Use the raw packet builder to model a peer that bypasses local sending
    // rules. A valid CRYPTO prefix must not be delivered before rejection.
    let payload = @quic.quic_encode_frames([
      Crypto(0L, b"not-delivered"),
      Stream(stream),
    ]).unwrap()
    let packet = @quic.quic_build_long_packet(
      keys.0,
      packet_type,
      1,
      server_id,
      client_id,
      b"",
      0L,
      1,
      payload,
      min_datagram_size=if space == Initial { 1200 } else { 0 },
    ).unwrap()
    assert_true(
      server.on_datagram(client_endpoint, packet, 1L) is Err(InvalidFrame(_)),
    )
    guard client.send_frames(space, [Crypto(0L, b"valid")], 2L).unwrap()
      is SendDatagram(_, valid_packet) else {
      fail("expected valid handshake packet")
    }
    let actions = server.on_datagram(client_endpoint, valid_packet, 3L).unwrap()
    assert_true(actions.contains(CryptoData(space, 0L, b"valid")))
  }
}

///|
test "quic driver state: application space retains post-handshake CRYPTO" {
  let endpoint = @types.Endpoint::new("udp", "example.test", 443).unwrap()
  let (client, server) = established_driver_pair(endpoint, endpoint)
  guard client.send_frames(Application, [Crypto(0L, b"ticket")], 0L).unwrap()
    is SendDatagram(_, packet) else {
    fail("expected post-handshake CRYPTO packet")
  }
  let actions = server.on_datagram(endpoint, packet, 1L).unwrap()
  assert_true(actions.contains(CryptoData(Application, 0L, b"ticket")))
}

///|
test "quic driver state: only the server sends NEW_TOKEN and HANDSHAKE_DONE" {
  let endpoint = @types.Endpoint::new("udp", "example.test", 443).unwrap()
  let (client, server) = established_driver_pair(endpoint, endpoint)
  let frames : Array[@quic.QuicFrame] = [NewToken(b"token"), HandshakeDone]
  for frame in frames {
    assert_true(
      client.send_frames(Application, [frame], 0L) is Err(Protocol(0x0aL, _)),
    )
  }
  guard server.send_frames(Application, frames, 1L).unwrap()
    is SendDatagram(_, packet) else {
    fail("expected a server datagram")
  }
  assert_true(client.on_datagram(endpoint, packet, 2L) is Ok(_))
}

///|
test "quic driver state: a close-only packet can leave a full recovery queue" {
  let endpoint = @types.Endpoint::new("udp", "example.test", 443).unwrap()
  let (client, server) = established_driver_pair(endpoint, endpoint, recovery_config={
    ..@quic.QuicRecoveryConfig::defaults(),
    max_tracked_packets: 1,
  })
  ignore(client.send_frames(Application, [Ping], 0L).unwrap())
  assert_true(
    client.send_frames(Application, [Ping], 1L) is Err(LimitExceeded(_, 1)),
  )
  guard client.send_frames(
      Application,
      [ConnectionClose(false, 0x100L, 0L, b"done")],
      2L,
    )
    is Ok(SendDatagram(_, packet)) else {
    fail("a close-only packet must not consume a recovery slot")
  }
  let actions = server.on_datagram(endpoint, packet, 3L).unwrap()
  assert_eq(actions, [ConnectionClosed(0x100L, "done")])
}

///|
test "quic driver pressure: concurrent streams survive deterministic loss and reordering" {
  let endpoint = @types.Endpoint::new("udp", "pressure.example", 443).unwrap()
  let (client, server) = established_driver_pair(endpoint, endpoint)
  let packets : Array[Bytes] = []
  let stream_ids : Array[Int64] = []
  for index in 0..<16 {
    let stream = client.connection().open_bidirectional_stream().unwrap()
    stream_ids.push(stream)
    let frame = @quic.StreamFrame::new(
      stream,
      0L,
      Bytes::from_array([index.to_byte(), b'\x01', b'\x02']),
      true,
    ).unwrap()
    guard client
      .send_frames(Application, [Stream(frame)], index.to_int64())
      .unwrap()
      is SendDatagram(_, packet) else {
      fail("expected concurrent stream packet")
    }
    packets.push(packet)
  }
  // Drop three original packets, including the newest packet, and deliver the
  // others backwards. The middle losses can be detected by ACKs; the missing
  // tail needs PTO because no later packet has yet been acknowledged.
  let queue : Array[(@quic.QuicDriverAction, Bool)] = []
  let delivered_ids : Array[Int64] = []
  for index in 0..<packets.length() {
    if index % 7 == 0 {
      continue
    }
    let packet = packets[packets.length() - index - 1]
    let actions = server
      .on_datagram(endpoint, packet, 100L + index.to_int64())
      .unwrap()
    for action in actions {
      queue.push((action, false))
    }
  }
  let mut now = 200L
  let mut timer_packets = 0
  let mut processed_actions = 0
  for _round in 0..<8 {
    while !queue.is_empty() {
      let (action, from_client) = queue.remove(0)
      processed_actions += 1
      assert_true(processed_actions < 1024)
      now += 1L
      match action {
        SendDatagram(_, packet) => {
          let recipient = if from_client { server } else { client }
          for response in recipient.on_datagram(endpoint, packet, now).unwrap() {
            queue.push((response, !from_client))
          }
        }
        StreamData(id, data, fin) => {
          assert_true(!from_client)
          assert_true(fin)
          assert_true(stream_ids.contains(id))
          assert_true(!delivered_ids.contains(id))
          let stream_index = for position, value in stream_ids; result = None {
            if value == id {
              continue Some(position)
            }
            continue result
          } nobreak {
            result
          }
          guard stream_index is Some(position) else {
            fail("missing concurrent stream index")
          }
          assert_eq(
            data,
            Bytes::from_array([position.to_byte(), b'\x01', b'\x02']),
          )
          delivered_ids.push(id)
        }
        _ => ()
      }
    }
    if delivered_ids.length() == stream_ids.length() {
      break
    }
    now += 2000L
    for action in client.poll(now).unwrap() {
      if action is SendDatagram(_, _) {
        timer_packets += 1
      }
      queue.push((action, true))
    }
    for action in server.poll(now).unwrap() {
      queue.push((action, false))
    }
  }
  // The reverse ACK flight can expose every loss by packet threshold before
  // a PTO deadline; timer_packets is diagnostic rather than a requirement of
  // this concurrent-stream delivery test.
  ignore(timer_packets)
  assert_eq(delivered_ids.length(), 16)
}

///|
test "quic driver path: two drivers validate and switch after challenge response" {
  let client_endpoint = @types.Endpoint::new("udp", "client.test", 443).unwrap()
  let original = @types.Endpoint::new("udp", "server.test", 443).unwrap()
  let candidate = @types.Endpoint::new("udp", "new-server.test", 443).unwrap()
  let (client, server) = established_driver_pair(client_endpoint, original)
  guard server.send_frames(Application, [HandshakeDone], 0L).unwrap()
    is SendDatagram(_, done) else {
    fail("expected handshake confirmation")
  }
  ignore(client.on_datagram(original, done, 0L).unwrap())
  guard client.begin_path_validation(candidate, b"12345678", 0L).unwrap()
    is SendDatagram(destination, challenge) else {
    fail("expected PATH_CHALLENGE action")
  }
  assert_eq(destination, candidate)
  assert_eq(challenge.length(), 1200)
  assert_eq(client.endpoint(), original)
  assert_eq(client.path_status(), PathChallenging)
  let probes = client.poll(2000L).unwrap()
  guard probes is [SendDatagram(probe_destination, _)] else {
    fail("expected candidate path PTO probe")
  }
  assert_eq(probe_destination, candidate)
  let responses = server.on_datagram(client_endpoint, challenge, 2001L).unwrap()
  guard responses is [SendDatagram(response_destination, response)] else {
    fail("expected protected PATH_RESPONSE")
  }
  assert_eq(response_destination, client_endpoint)
  assert_eq(response.length(), 1200)
  let actions = client.on_datagram(candidate, response, 2002L).unwrap()
  assert_true(actions.contains(PathValidated(candidate)))
  assert_eq(client.endpoint(), candidate)
  assert_eq(client.path_status(), PathValidated)
  guard client.send_frames(Application, [Ping], 2003L).unwrap()
    is SendDatagram(active, _) else {
    fail("expected application packet on new path")
  }
  assert_eq(active, candidate)
}

///|
test "quic driver path: candidate packets cannot mutate streams before validation" {
  let client_endpoint = @types.Endpoint::new("udp", "client.test", 443).unwrap()
  let original = @types.Endpoint::new("udp", "server.test", 443).unwrap()
  let candidate = @types.Endpoint::new("udp", "new-server.test", 443).unwrap()
  let (client, server) = established_driver_pair(client_endpoint, original)
  ignore(client.begin_path_validation(candidate, b"12345678", 0L).unwrap())
  guard server.send_frames(Application, [Ping], 1L).unwrap()
    is SendDatagram(_, premature_packet) else {
    fail("expected premature application packet")
  }
  assert_true(
    client.on_datagram(candidate, premature_packet, 2L) is Err(InvalidPacket(_)),
  )
  // Rejection must not consume the packet number or prevent processing an
  // identical packet that arrives later on the active path.
  assert_true(client.on_datagram(original, premature_packet, 3L) is Ok(_))
  let stream = @quic.StreamFrame::new(1L, 0L, b"unvalidated", true).unwrap()
  guard server
    .send_frames(Application, [PathResponse(b"12345678"), Stream(stream)], 4L)
    .unwrap()
    is SendDatagram(_, mixed_packet) else {
    fail("expected mixed response packet")
  }
  assert_true(
    client.on_datagram(candidate, mixed_packet, 5L) is Err(InvalidPacket(_)),
  )
  assert_eq(client.endpoint(), original)
  assert_eq(client.path_status(), PathChallenging)
  guard server
    .send_frames(Application, [PathResponse(b"wrong!!!")], 6L)
    .unwrap()
    is SendDatagram(_, wrong_packet) else {
    fail("expected mismatching PATH_RESPONSE")
  }
  assert_true(
    client.on_datagram(candidate, wrong_packet, 7L) is Err(InvalidPacket(_)),
  )
  assert_eq(client.path_status(), PathChallenging)
}

///|
test "quic driver path: matching response on active path validates candidate" {
  let endpoint = @types.Endpoint::new("udp", "example.test", 443).unwrap()
  let candidate = @types.Endpoint::new("udp", "candidate.test", 443).unwrap()
  let (client, server) = established_driver_pair(endpoint, endpoint)
  ignore(client.begin_path_validation(candidate, b"12345678", 0L).unwrap())
  guard server
    .send_frames(Application, [PathResponse(b"12345678")], 1L)
    .unwrap()
    is SendDatagram(_, packet) else {
    fail("expected PATH_RESPONSE")
  }
  let actions = client.on_datagram(endpoint, packet, 2L).unwrap()
  assert_true(actions.contains(PathValidated(candidate)))
  assert_eq(client.endpoint(), candidate)
}

///|
test "quic keys: confirmation and ACK gates, peer response and bounded old-key retention" {
  // Clock origins are independent of the QUIC wire varint range.
  let start = 1L << 62
  let endpoint = @types.Endpoint::new("udp", "example.test", 443).unwrap()
  let (client, server) = established_driver_pair(endpoint, endpoint)
  assert_true(client.initiate_key_update() is Err(Unsupported(_)))
  assert_true(server.initiate_key_update() is Err(Unsupported(_)))
  guard client.send_frames(Application, [Ping], start).unwrap()
    is SendDatagram(_, first) else {
    fail("expected packet")
  }
  guard server.on_datagram(endpoint, first, start + 1L).unwrap()
    is [SendDatagram(_, ack)] else {
    fail("expected ACK")
  }
  ignore(client.on_datagram(endpoint, ack, start + 2L).unwrap())
  assert_true(client.handshake_confirmed())
  guard client.send_frames(Application, [Ping], start + 3L).unwrap()
    is SendDatagram(_, reordered) else {
    fail("expected packet")
  }
  guard client.send_frames(Application, [Ping], start + 4L).unwrap()
    is SendDatagram(_, expired) else {
    fail("expected packet")
  }
  client.initiate_key_update().unwrap()
  assert_true(client.initiate_key_update() is Err(Unsupported(_)))
  guard client.send_frames(Application, [Ping], start + 5L).unwrap()
    is SendDatagram(_, updated) else {
    fail("expected packet")
  }
  guard server.on_datagram(endpoint, updated, start + 6L).unwrap()
    is [SendDatagram(_, updated_ack)] else {
    fail("expected updated ACK")
  }
  // The new-phase ACK authenticates with newly derived keys at the client.
  ignore(client.on_datagram(endpoint, updated_ack, start + 7L).unwrap())
  assert_true(server.on_datagram(endpoint, reordered, start + 8L) is Ok(_))
  assert_true(server.on_datagram(endpoint, expired, start + 100000L) is Err(_))
  client.initiate_key_update().unwrap()
}

///|
test "quic stream packet rejection preserves offsets and reset final size" {
  let endpoint = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  let (client, server) = established_driver_pair(endpoint, endpoint)
  let id = client.connection().open_bidirectional_stream().unwrap()
  let oversized = Bytes::from_array(FixedArray::make(2048, b'x'))
  assert_true(client.send_stream(id, oversized, true, 0L) is Err(_))
  guard client.send_stream(id, b"abc", false, 1L) is Ok(SendDatagram(_, packet)) else {
    fail("expected stream packet after retry")
  }
  assert_true(
    server
    .on_datagram(endpoint, packet, 2L)
    .unwrap()
    .contains(StreamData(id, b"abc", false)),
  )
  guard client.reset_stream(id, 42L, 3L) is Ok(SendDatagram(_, reset)) else {
    fail("expected reset packet")
  }
  assert_true(
    server
    .on_datagram(endpoint, reset, 4L)
    .unwrap()
    .contains(StreamReset(id, 42L)),
  )
  assert_true(client.send_stream(id, b"x", false, 5L) is Err(StreamClosed(_)))
  assert_true(server.send_stream(id, b"ok", true, 6L) is Ok(_))
}

///|
test "quic driver retransmits stream data when the loss timer expires in silence" {
  let endpoint = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  let (client, server) = established_driver_pair(endpoint, endpoint)
  let id = client.connection().open_bidirectional_stream().unwrap()
  ignore(client.send_stream(id, b"ordered", true, 0L).unwrap())
  guard client.send_frames(Application, [Ping], 0L).unwrap()
    is SendDatagram(_, ping) else {
    fail("expected packet following the missing stream data")
  }
  guard server.on_datagram(endpoint, ping, 0L).unwrap()
    is [SendDatagram(_, ack)] else {
    fail("expected ACK for the later packet")
  }
  assert_eq(client.on_datagram(endpoint, ack, 80L).unwrap(), [])
  assert_eq(client.poll(89L).unwrap(), [])
  guard client.poll(90L).unwrap() is [SendDatagram(_, retry)] else {
    fail("expected timer-driven stream retransmission")
  }
  let received = server.on_datagram(endpoint, retry, 91L).unwrap()
  assert_true(received.contains(StreamData(id, b"ordered", true)))
  assert_eq(client.poll(91L).unwrap(), [])
}

///|
test "QUIC driver honors the negotiated idle timeout" {
  let endpoint = @types.Endpoint::new("udp", "127.0.0.1", 443).unwrap()
  let server = @quic.ConnectionId::new(b"server-id").unwrap()
  let client = @quic.ConnectionId::new(b"client-id").unwrap()
  for
    (local_idle, remote_idle, expires) in [
      (30000L, 10000L, Some(10000L)),
      (10000L, 30000L, Some(10000L)),
      (0L, 10000L, Some(10000L)),
      (10000L, 0L, Some(10000L)),
      // Initial RTT 100ms, variance 50ms and peer max_ack_delay 25ms.
      (1L, 1L, Some(975L)),
      (0L, 0L, None),
    ] {
    let local_limits = {
      ..@quic.QuicTransportParams::defaults(),
      max_idle_timeout: local_idle,
    }
    let driver = @quic.QuicDatagramDriver::new(
      Server,
      endpoint,
      server,
      server,
      client,
      transport_params=local_limits,
      recovery_config={
        ..@quic.QuicRecoveryConfig::defaults(),
        initial_rtt_ms: 100L,
      },
    ).unwrap()
    let keys = @quic.quic_initial_packet_keys(server).unwrap()
    driver.install_handshake_keys(keys.1, keys.0).unwrap()
    driver.install_application_keys(keys.1, keys.0).unwrap()
    let limits = { ..local_limits, max_idle_timeout: remote_idle, }
    driver
    .set_peer_transport_parameters(
      @quic.QuicTransportParameters::new(client, limits~),
    )
    .unwrap()
    driver.establish().unwrap()
    if expires is Some(ms) {
      ignore(driver.poll(ms - 1L).unwrap())
      assert_eq(driver.state(), Established)
      ignore(driver.poll(ms).unwrap())
      assert_eq(driver.state(), Closed)
    } else {
      ignore(driver.poll(60000L).unwrap())
      assert_eq(driver.state(), Established)
    }
  }
}
