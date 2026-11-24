///|
test "quic datagram driver: protected Initial loopback and duplicate drop" {
  let endpoint = @types.Endpoint::new("udp", "example.test", 443).unwrap()
  let server_id = @quic.ConnectionId::new(b"server-id").unwrap()
  let client_id = @quic.ConnectionId::new(b"client-id").unwrap()
  let client = @quic.QuicDatagramDriver::new(
    Client,
    endpoint,
    server_id,
    client_id,
    server_id,
  ).unwrap()
  let server = @quic.QuicDatagramDriver::new(
    Server,
    endpoint,
    server_id,
    server_id,
    client_id,
  ).unwrap()
  let outgoing = match client.send_frames(Initial, [Ping], 1L) {
    Ok(value) => value
    Err(LimitExceeded(label, _)) => fail(label)
    Err(InvalidPacket(message)) => fail(message)
    Err(InvalidFrame(message)) => fail(message)
    Err(FlowControl(_, message)) => fail(message)
    Err(error) => {
      ignore(error)
      fail("unexpected driver error")
    }
  }
  guard outgoing is SendDatagram(_, packet) else {
    fail("expected an outgoing datagram")
  }
  assert_true(packet.length() >= 1200)
  let server_actions = server.on_datagram(endpoint, packet, 2L).unwrap()
  assert_true(server_actions.any(fn(action) { action is SendDatagram(_, _) }))
  let mut response_packet : Bytes? = None
  for action in server_actions {
    match action {
      SendDatagram(_, bytes) => response_packet = Some(bytes)
      _ => ()
    }
  }
  let response_packet = response_packet.unwrap()
  guard response_packet.length() > 0 else { fail("expected server response") }
  let client_actions = client
    .on_datagram(endpoint, response_packet, 3L)
    .unwrap()
  assert_true(client_actions.is_empty())
  assert_eq(client.on_datagram(endpoint, response_packet, 4L).unwrap(), [
    PacketIgnored,
  ])
}

///|
test "quic datagram driver: server amplification budget is path scoped" {
  let endpoint = @types.Endpoint::new("udp", "example.test", 443).unwrap()
  let server_id = @quic.ConnectionId::new(b"server-id").unwrap()
  let client_id = @quic.ConnectionId::new(b"client-id").unwrap()
  let client = @quic.QuicDatagramDriver::new(
    Client,
    endpoint,
    server_id,
    client_id,
    server_id,
  ).unwrap()
  let server = @quic.QuicDatagramDriver::new(
    Server,
    endpoint,
    server_id,
    server_id,
    client_id,
  ).unwrap()
  assert_true(
    server.send_frames(Initial, [Ping], 0L) is Err(AmplificationBlocked),
  )
  guard client.send_frames(Initial, [Ping], 1L).unwrap()
    is SendDatagram(_, client_packet) else {
    fail("expected client Initial datagram")
  }
  let server_actions = server.on_datagram(endpoint, client_packet, 2L).unwrap()
  for action in server_actions {
    match action {
      SendDatagram(_, bytes) =>
        assert_true(bytes.length() <= client_packet.length() * 3)
      _ => ()
    }
  }
  guard server.send_frames(Initial, [Ping], 3L).unwrap()
    is SendDatagram(_, response) else {
    fail("expected server output after receiving an attributable datagram")
  }
  assert_true(response.length() <= client_packet.length() * 3)
}

///|
test "quic datagram driver: CRYPTO actions preserve stream offsets" {
  let endpoint = @types.Endpoint::new("udp", "example.test", 443).unwrap()
  let server_id = @quic.ConnectionId::new(b"server-id").unwrap()
  let client_id = @quic.ConnectionId::new(b"client-id").unwrap()
  let client = @quic.QuicDatagramDriver::new(
    Client,
    endpoint,
    server_id,
    client_id,
    server_id,
  ).unwrap()
  let server = @quic.QuicDatagramDriver::new(
    Server,
    endpoint,
    server_id,
    server_id,
    client_id,
  ).unwrap()
  guard client.send_frames(Initial, [Crypto(3L, b"lo")], 0L).unwrap()
    is SendDatagram(_, first_packet) else {
    fail("expected first CRYPTO datagram")
  }
  ignore(server.on_datagram(endpoint, first_packet, 1L).unwrap())
  guard client.send_frames(Initial, [Crypto(0L, b"hel")], 2L).unwrap()
    is SendDatagram(_, second_packet) else {
    fail("expected second CRYPTO datagram")
  }
  let actions = server.on_datagram(endpoint, second_packet, 3L).unwrap()
  assert_true(
    actions.any(fn(action) {
      match action {
        CryptoData(Initial, offset, data) => offset == 0L && data == b"hello"
        _ => false
      }
    }),
  )
}

///|
test "quic datagram driver: packet deduplication window stays bounded" {
  let endpoint = @types.Endpoint::new("udp", "example.test", 443).unwrap()
  let server_id = @quic.ConnectionId::new(b"server-id").unwrap()
  let client_id = @quic.ConnectionId::new(b"client-id").unwrap()
  let server = @quic.QuicDatagramDriver::new(
    Server,
    endpoint,
    server_id,
    server_id,
    client_id,
  ).unwrap()
  let keys = @quic.quic_initial_packet_key(server_id, Client).unwrap()
  let packet = fn(number) {
    let options = @quic.QuicInitialPacketOptions::defaults(
      server_id, client_id, number,
    )
    @quic.quic_build_initial_packet(keys, options, b"\x00").unwrap()
  }
  for number in [0L, 4095L, 4096L] {
    assert_eq(server.on_datagram(endpoint, packet(number), number).unwrap(), [])
  }
  assert_eq(server.on_datagram(endpoint, packet(0L), 4097L).unwrap(), [
    PacketIgnored,
  ])
  assert_eq(server.on_datagram(endpoint, packet(4095L), 4098L).unwrap(), [
    PacketIgnored,
  ])
  // An unseen packet just inside the window is still accepted.
  assert_eq(server.on_datagram(endpoint, packet(1L), 4099L).unwrap(), [])
}

///|
test "quic datagram driver: multiple losses are retransmitted as separate packets" {
  let endpoint = @types.Endpoint::new("udp", "example.test", 443).unwrap()
  let server_id = @quic.ConnectionId::new(b"server-id").unwrap()
  let client_id = @quic.ConnectionId::new(b"client-id").unwrap()
  let client = @quic.QuicDatagramDriver::new(
    Client,
    endpoint,
    server_id,
    client_id,
    server_id,
  ).unwrap()
  let server = @quic.QuicDatagramDriver::new(
    Server,
    endpoint,
    server_id,
    server_id,
    client_id,
  ).unwrap()
  let keys = @quic.quic_initial_packet_keys(server_id).unwrap()
  client.install_handshake_keys(keys.0, keys.1).unwrap()
  server.install_handshake_keys(keys.1, keys.0).unwrap()
  let payload = Bytes::from_array(FixedArray::make(700, b'x'))
  for number in 0..<7 {
    let offset = number.to_int64() * payload.length().to_int64()
    let sent = client
      .send_frames(Handshake, [Crypto(offset, payload)], number.to_int64())
      .unwrap()
    guard sent is SendDatagram(_, packet) else {
      fail("expected protected handshake datagram")
    }
    // Account the complete datagram on the server path before asking it to
    // emit an ACK; this is the real address-validation precondition.
    ignore(server.on_datagram(endpoint, packet, number.to_int64()).unwrap())
  }
  let range = @quic.AckRange::new(6L, 6L).unwrap()
  let ack = @quic.AckFrame::new(6L, 0L, [range]).unwrap()
  let ack_action = server.send_frames(Handshake, [Ack(ack)], 90L).unwrap()
  guard ack_action is SendDatagram(_, ack_packet) else {
    fail("expected protected ACK datagram")
  }
  let actions = client.on_datagram(endpoint, ack_packet, 100L).unwrap()
  assert_eq(actions.length(), 4)
  for action in actions {
    guard action is SendDatagram(_, packet) else {
      fail("expected one datagram per lost packet")
    }
    assert_true(packet.length() <= @quic.QuicLimits::defaults().max_packet_size)
    let (offset, _) = @quic.quic_long_header_packet_layout(packet).unwrap()
    let opened = @quic.quic_open_packet_with_keys(
      keys.0,
      packet,
      offset,
      6L,
      true,
    ).unwrap()
    guard @quic.quic_decode_frames(opened.payload()).unwrap()
      is [Crypto(_, data)] else {
      fail("expected one retained CRYPTO frame")
    }
    assert_eq(data.length(), 700)
  }
}
