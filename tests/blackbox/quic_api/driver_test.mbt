///|
test "QUIC receives a larger Initial while retaining its outgoing path budget" {
  let peer = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  let dst = @quic.ConnectionId::new(b"server-id").unwrap()
  let src = @quic.ConnectionId::new(b"client-id").unwrap()
  assert_true(
    @quic.QuicConnection::new(Client, limits={
      ..@quic.QuicLimits::defaults(),
      max_packet_size: 1199,
    })
    is Err(InvalidTransportParameter(_)),
  )
  let server = @quic.QuicDatagramDriver::new(Server, peer, dst, dst, src, limits={
    ..@quic.QuicLimits::defaults(),
    max_datagram_size: 1400,
  }).unwrap()
  assert_eq(
    server.connection().local_transport_params().max_udp_payload_size,
    1400,
  )
  let keys = @quic.quic_initial_packet_keys(dst).unwrap()
  let packet = @quic.quic_build_initial_packet(
    keys.0,
    {
      ..@quic.QuicInitialPacketOptions::defaults(dst, src, 0L),
      min_datagram_size: 1280,
    },
    @quic.quic_encode_frames([Ping]).unwrap(),
  ).unwrap()
  assert_eq(packet.length(), 1280)
  assert_true(server.on_datagram(peer, packet, 0L) is Ok([SendDatagram(_, _)]))
  assert_eq(
    server.send_frames(Initial, [Crypto(0L, Bytes::make(1220, b'x'))], 1L),
    Err(InvalidPacket("packet exceeds datagram limit")),
  )
}

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
test "quic crypto reassembler: sparse fragments and repeated overlap have bounded work" {
  let sparse = @quic.QuicCryptoReassembler::new(max_bytes=1024, max_segments=8).unwrap()
  for index in 0..<8 {
    assert_eq(sparse.feed((index * 2 + 1).to_int64(), b"a").unwrap(), [])
  }
  assert_true(
    sparse.feed(17L, b"a")
    is Err(LimitExceeded("CRYPTO reassembly fragments", 8)),
  )
  assert_eq(sparse.feed(0L, b"a").unwrap(), [b"aa"])
  assert_eq(sparse.feed(17L, b"a").unwrap(), [])
  let work = @quic.QuicCryptoReassembler::new(max_bytes=32, max_work=6L).unwrap()
  assert_eq(work.feed(0L, b"abc").unwrap(), [b"abc"])
  assert_eq(work.feed(0L, b"abc").unwrap(), [])
  assert_true(
    work.feed(0L, b"a") is Err(LimitExceeded("CRYPTO reassembly work", 6)),
  )
}

///|
test "quic datagram driver: handshake keys are an explicit capability" {
  let endpoint = @types.Endpoint::new("udp", "example.test", 443).unwrap()
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
  let endpoint = @types.Endpoint::new("udp", "example.test", 443).unwrap()
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
  let endpoint = @types.Endpoint::new("udp", "example.test", 443).unwrap()
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
  let blocked = @types.Endpoint::new("udp", "blocked.example", 443).unwrap()
  assert_eq(
    driver.begin_path_validation(blocked, b"12345678", 0L),
    Err(Policy(Denied(QuicEndpoint, "path denied"))),
  )
  assert_eq(driver.endpoint(), endpoint)
  assert_eq(driver.path_status(), PathActive)
}

///|
test "quic datagram driver: establishment requires application keys" {
  let endpoint = @types.Endpoint::new("udp", "example.test", 443).unwrap()
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
  let endpoint = @types.Endpoint::new("udp", "example.test", 443).unwrap()
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
  let keys = @quic.quic_initial_packet_key(destination, Client).unwrap()
  for (now, previous) in [(2000L, 0L), (4000L, 1L)] {
    guard driver.poll(now).unwrap() is [SendDatagram(_, packet)] else {
      fail("expected protected CRYPTO at each PTO")
    }
    let (offset, _) = @quic.quic_long_header_packet_layout(packet).unwrap()
    let opened = @quic.quic_open_packet_with_keys(
      keys, packet, offset, previous, true,
    ).unwrap()
    let frames = @quic.quic_decode_frames(opened.payload()).unwrap()
    assert_true(frames.contains(Crypto(0L, b"handshake")))
  }
}

///|
test "quic datagram driver: retransmission retention is bounded" {
  let endpoint = @types.Endpoint::new("udp", "example.test", 443).unwrap()
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
  ignore(driver.send_frames(Initial, [Crypto(0L, b"a")], 0L).unwrap())
  assert_true(
    driver.send_frames(Initial, [Crypto(1L, b"next")], 1L)
    is Err(LimitExceeded("QUIC retransmission queue", 1)),
  )
}
