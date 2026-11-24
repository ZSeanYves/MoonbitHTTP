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
