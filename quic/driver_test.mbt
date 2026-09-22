///|
test "quic crypto reassembler: out of order and duplicate ranges" {
  let reassembler = @quic.QuicCryptoReassembler::new(max_bytes=32).unwrap()
  assert_eq(reassembler.feed(3L, b"lo").unwrap(), [])
  assert_eq(reassembler.feed(0L, b"hel").unwrap(), [b"hello"])
  assert_eq(reassembler.feed(1L, b"e").unwrap(), [])
  assert_true(reassembler.feed(0L, b"HEY") is Err(_))
  assert_true(reassembler.feed(31L, b"xx") is Err(_))
}

///|
test "quic datagram driver: protected Initial loopback and duplicate drop" {
  let endpoint = @transport.Endpoint::new("udp", "example.test", 443).unwrap()
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
test "quic datagram driver: CRYPTO actions preserve stream offsets" {
  let endpoint = @transport.Endpoint::new("udp", "example.test", 443).unwrap()
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
  let endpoint = @transport.Endpoint::new("udp", "example.test", 443).unwrap()
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
  let mut retained_packet : Bytes? = None
  for number in 0..<4097 {
    guard client.send_frames(Initial, [Padding], number.to_int64()).unwrap()
      is SendDatagram(_, packet) else {
      fail("expected padding datagram")
    }
    if number == 4090 {
      retained_packet = Some(packet)
    }
    ignore(server.on_datagram(endpoint, packet, number.to_int64()).unwrap())
  }
  assert_eq(
    server.on_datagram(endpoint, retained_packet.unwrap(), 4097L).unwrap(),
    [PacketIgnored],
  )
}

///|
test "quic datagram driver: handshake keys are an explicit capability" {
  let endpoint = @transport.Endpoint::new("udp", "example.test", 443).unwrap()
  let destination = @quic.ConnectionId::new(b"server-id").unwrap()
  let local_id = @quic.ConnectionId::new(b"client-id").unwrap()
  let driver = @quic.QuicDatagramDriver::new(
    Client,
    endpoint,
    destination,
    local_id,
    destination,
  ).unwrap()
  assert_true(driver.send_frames(Handshake, [Ping], 0L) is Err(Unsupported(_)))
}

///|
test "quic datagram driver: application packets fail closed before establishment" {
  let endpoint = @transport.Endpoint::new("udp", "example.test", 443).unwrap()
  let destination = @quic.ConnectionId::new(b"server-id").unwrap()
  let local_id = @quic.ConnectionId::new(b"client-id").unwrap()
  let driver = @quic.QuicDatagramDriver::new(
    Client,
    endpoint,
    destination,
    local_id,
    destination,
  ).unwrap()
  assert_true(
    driver.send_frames(Application, [Ping], 0L) is Err(Unsupported(_)),
  )
}

///|
test "quic datagram driver: path migration is policy checked before state change" {
  let endpoint = @transport.Endpoint::new("udp", "example.test", 443).unwrap()
  let destination = @quic.ConnectionId::new(b"server-id").unwrap()
  let local_id = @quic.ConnectionId::new(b"client-id").unwrap()
  let driver = @quic.QuicDatagramDriver::new(
    Client,
    endpoint,
    destination,
    local_id,
    destination,
    authorize=fn(candidate, operation) {
      if candidate.host() == "blocked.example" {
        Err(Denied(operation, "path denied"))
      } else {
        Ok(())
      }
    },
  ).unwrap()
  let blocked = @transport.Endpoint::new("udp", "blocked.example", 443).unwrap()
  assert_eq(
    driver.begin_path_validation(blocked, b"12345678"),
    Err(Policy(Denied(QuicEndpoint, "path denied"))),
  )
  assert_eq(driver.endpoint(), endpoint)
  assert_eq(driver.path_status(), PathActive)
}

///|
test "quic datagram driver: establishment requires application keys" {
  let endpoint = @transport.Endpoint::new("udp", "example.test", 443).unwrap()
  let destination = @quic.ConnectionId::new(b"server-id").unwrap()
  let local_id = @quic.ConnectionId::new(b"client-id").unwrap()
  let driver = @quic.QuicDatagramDriver::new(
    Client,
    endpoint,
    destination,
    local_id,
    destination,
  ).unwrap()
  assert_true(driver.establish() is Err(Unsupported(_)))
}

///|
test "quic datagram driver: PTO retransmits retained frames" {
  let endpoint = @transport.Endpoint::new("udp", "example.test", 443).unwrap()
  let destination = @quic.ConnectionId::new(b"server-id").unwrap()
  let local_id = @quic.ConnectionId::new(b"client-id").unwrap()
  let driver = @quic.QuicDatagramDriver::new(
    Client,
    endpoint,
    destination,
    local_id,
    destination,
  ).unwrap()
  ignore(driver.send_frames(Initial, [Crypto(0L, b"handshake")], 0L).unwrap())
  let actions = driver.poll(2000L).unwrap()
  guard actions is [SendDatagram(_, packet)] else {
    fail("expected a PTO retransmission")
  }
  let (offset, _) = @quic.quic_long_header_packet_layout(packet).unwrap()
  let keys = @quic.quic_initial_packet_key(destination, Client).unwrap()
  let opened = @quic.quic_open_packet_with_keys(keys, packet, offset, 0L, true).unwrap()
  let frames = @quic.quic_decode_frames(opened.payload()).unwrap()
  assert_true(
    frames.any(fn(frame) {
      match frame {
        Crypto(offset, data) => offset == 0L && data == b"handshake"
        _ => false
      }
    }),
  )
}

///|
test "quic datagram driver: retransmission retention is bounded" {
  let endpoint = @transport.Endpoint::new("udp", "example.test", 443).unwrap()
  let destination = @quic.ConnectionId::new(b"server-id").unwrap()
  let local_id = @quic.ConnectionId::new(b"client-id").unwrap()
  let recovery_config : @quic.QuicRecoveryConfig = {
    ..@quic.QuicRecoveryConfig::defaults(),
    max_tracked_packets: 1,
  }
  let driver = @quic.QuicDatagramDriver::new(
    Client,
    endpoint,
    destination,
    local_id,
    destination,
    recovery_config~,
  ).unwrap()
  ignore(driver.send_frames(Initial, [Ping], 0L).unwrap())
  assert_true(
    driver.send_frames(Initial, [Crypto(0L, b"next")], 1L)
    is Err(LimitExceeded(_)),
  )
}

///|
test "quic datagram driver: multiple losses are retransmitted as separate packets" {
  let endpoint = @transport.Endpoint::new("udp", "example.test", 443).unwrap()
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
    ignore(
      client
      .send_frames(Handshake, [Crypto(offset, payload)], number.to_int64())
      .unwrap(),
    )
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
    assert_true(
      packet.length() <=
      @quic.QuicTransportParams::defaults().max_udp_payload_size,
    )
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
