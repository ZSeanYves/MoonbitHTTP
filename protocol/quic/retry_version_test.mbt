///|
test "quic retry: integrity binds original destination and rotates Initial keys" {
  let endpoint = @types.Endpoint::new("udp", "retry.example", 443).unwrap()
  let original = @quic.ConnectionId::new(b"original-dcid").unwrap()
  let client_id = @quic.ConnectionId::new(b"client-source").unwrap()
  let retry_id = @quic.ConnectionId::new(b"retry-source").unwrap()
  let client = @quic.QuicDatagramDriver::new(
    Client,
    endpoint,
    original,
    client_id,
    original,
  ).unwrap()
  ignore(client.send_frames(Initial, [Crypto(0L, b"clienthello")], 0L).unwrap())
  let retry = @quic.quic_build_retry_packet(
    @quic.QUIC_VERSION_1,
    client_id,
    retry_id,
    b"address-token",
    original,
  ).unwrap()
  let retry_actions = client.on_datagram(endpoint, retry, 1L).unwrap()
  guard retry_actions is [RetryReceived(id), ..] else {
    fail("expected validated Retry")
  }
  assert_eq(id, retry_id)
  guard client
    .send_frames(Initial, [Crypto(0L, b"retry-clienthello")], 2L)
    .unwrap()
    is SendDatagram(_, packet) else {
    fail("expected Initial after Retry")
  }
  let (header, _) = @quic.quic_decode_packet_header(packet).unwrap()
  guard header is Initial(value) else { fail("expected Initial header") }
  assert_eq(value.destination, retry_id)
  assert_eq(value.token, b"address-token")
  let corrupted = retry.to_array()
  corrupted[corrupted.length() - 1] = corrupted[corrupted.length() - 1] ^ 1
  let second = @quic.QuicDatagramDriver::new(
    Client,
    endpoint,
    original,
    client_id,
    original,
  ).unwrap()
  ignore(second.send_frames(Initial, [Crypto(0L, b"clienthello")], 0L).unwrap())
  assert_true(
    second.on_datagram(endpoint, Bytes::from_array(corrupted), 1L)
    is Ok([PacketIgnored]),
  )
}

///|
test "quic retry: server helper emits a bounded response after Initial" {
  let endpoint = @types.Endpoint::new("udp", "retry-server.example", 443).unwrap()
  let original = @quic.ConnectionId::new(b"original-dcid").unwrap()
  let client_id = @quic.ConnectionId::new(b"client-source").unwrap()
  let server_id = @quic.ConnectionId::new(b"server-source").unwrap()
  let client = @quic.QuicDatagramDriver::new(
    Client,
    endpoint,
    original,
    client_id,
    original,
  ).unwrap()
  let server = @quic.QuicDatagramDriver::new(
    Server,
    endpoint,
    original,
    server_id,
    client_id,
    retry_tokens=Some(
      @quic.QuicRetryTokenManager::new(b"01234567890123456789012345678901").unwrap(),
    ),
  ).unwrap()
  guard client.send_frames(Initial, [Crypto(0L, b"clienthello")], 0L).unwrap()
    is SendDatagram(_, initial) else {
    fail("expected Initial")
  }
  ignore(server.on_datagram(endpoint, initial, 1L).unwrap())
  guard server.send_retry_validated(
      endpoint,
      @test_support.FixedClock::new(1L, 0L),
      @test_support.ZeroEntropy::new(),
    )
    is Ok(SendDatagram(_, retry)) else {
    fail("expected server Retry")
  }
  let (header, _) = @quic.quic_decode_packet_header(retry).unwrap()
  guard header is Retry(value) else { fail("expected Retry header") }
  assert_true(!value.token.is_empty())
}

///|
test "quic version negotiation: server responds and client rejects unsupported list" {
  let endpoint = @types.Endpoint::new("udp", "version.example", 443).unwrap()
  let client_id = @quic.ConnectionId::new(b"client-source").unwrap()
  let server_id = @quic.ConnectionId::new(b"server-source").unwrap()
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
  ignore(client.send_frames(Initial, [Crypto(0L, b"clienthello")], 0L).unwrap())
  // A syntactically valid unsupported long header is enough to exercise the
  // stateless Version Negotiation branch; no packet keys are required.
  let unsupported = @quic.quic_build_version_negotiation_packet(
    client_id,
    server_id,
    [0x0aceb00c],
  ).unwrap()
  let unsupported_result = client.on_datagram(endpoint, unsupported, 1L)
  guard unsupported_result is Err(VersionNegotiation(_)) else {
    fail("expected unsupported version failure")
  }
  let incoming = @quic.quic_build_version_negotiation_packet(
    client_id,
    server_id,
    [@quic.QUIC_VERSION_1],
  ).unwrap()
  // Version Negotiation packets are ignored by a server; they cannot create
  // state or be reflected as a connection response.
  assert_true(
    server.on_datagram(endpoint, incoming, 1L).unwrap().contains(PacketIgnored),
  )
}
