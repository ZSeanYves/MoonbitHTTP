///|
/// A real OpenSSL QUIC handshake through Retry. The first ClientHello is
/// intentionally withheld after the server has observed it; the server emits
/// Retry, the client validates the RFC tag and retransmits the retained CRYPTO
/// bytes under the new Initial keys, and a fresh server TLS endpoint completes
/// the handshake. This catches the common bug where Retry is parsed by the
/// packet codec but bypasses the TLS driver.
async test "native QUIC Retry replays ClientHello and completes TLS" {
  let (client_options, server_options) = fixture_options()
  let endpoint = @types.Endpoint::new("udp", "127.0.0.1", 443).unwrap()
  let original = @quic.ConnectionId::new(b"original").unwrap()
  let client_id = @quic.ConnectionId::new(b"client-id").unwrap()
  let retry_id = @quic.ConnectionId::new(b"retry-id").unwrap()
  let transport_params = {
    ..@quic.QuicTransportParams::defaults(),
    max_udp_payload_size: 1400,
  }
  let retry_manager = @quic.QuicRetryTokenManager::new(
    b"01234567890123456789012345678901",
  ).unwrap()
  let client_packets = @quic.QuicDatagramDriver::new(
    Client,
    endpoint,
    original,
    client_id,
    original,
    transport_params~,
  ).unwrap()
  let server_packets = @quic.QuicDatagramDriver::new(
    Server,
    endpoint,
    original,
    retry_id,
    client_id,
    transport_params~,
    retry_tokens=Some(retry_manager),
  ).unwrap()
  let client_provider = NativeQuicTlsProvider::new(allow_system_roots=false)
  let server_provider = NativeQuicTlsProvider::new(
    server=true,
    allow_system_roots=false,
  )
  defer {
    client_provider.close()
    server_provider.close()
  }
  let client = @quic.QuicTlsDriver::new(client_packets, client_provider).unwrap()
  let server = @quic.QuicTlsDriver::new(server_packets, server_provider).unwrap()
  let client_start = client
    .start({ ..client_options, alpn: ["h3"], }, 0L)
    .unwrap()
  ignore(server.start({ ..server_options, alpn: ["h3"], }, 0L).unwrap())
  let first_initial = for action in client_start; result = None {
    match action {
      SendDatagram(_, bytes) => continue Some(bytes)
      _ => continue result
    }
  } nobreak {
    result
  }
  let first_initial = match first_initial {
    Some(bytes) => bytes
    None => fail("expected client Initial")
  }
  // Let the server process ClientHello so it can construct a Retry response.
  ignore(server.on_datagram(endpoint, first_initial, 1L).unwrap())
  let retry = server
    .datagram_driver()
    .send_retry_validated(
      endpoint,
      @test_support.FixedClock::new(1L, 0L),
      @test_support.ZeroEntropy::new(),
    )
    .unwrap()
  guard retry is SendDatagram(_, retry_packet) else {
    fail("expected Retry packet")
  }
  let client_retry = match client.on_datagram(endpoint, retry_packet, 2L) {
    Ok(value) => value
    Err(error) => fail("Retry delivery failed: \{Repr(error)}")
  }
  guard client_retry.any(fn(action) {
    match action {
      RetryReceived(id) => id == retry_id
      _ => false
    }
  }) else {
    // The server's CID is the Retry SCID. The helper uses server_id here, so
    // the assertion below documents the actual wire identity instead.
    fail("expected validated Retry notification")
  }
  guard client_retry.any(fn(action) {
    match action {
      SendDatagram(_, _) => true
      _ => false
    }
  }) else {
    fail("expected replayed ClientHello")
  }
  let retry_source = server.datagram_driver().local_connection_id()
  let retry_token = match @quic.quic_decode_packet_header(retry_packet) {
    Ok((Retry(value), _)) => value.token
    _ => fail("expected Retry token")
  }
  let retry_context = retry_manager
    .validate_initial(endpoint, retry_token, 3L)
    .unwrap()
  let server2_packets = @quic.QuicDatagramDriver::new(
    Server,
    endpoint,
    retry_source,
    retry_id,
    client_id,
    transport_params~,
    retry_context=Some(retry_context),
    now_ms=3L,
    retry_tokens=Some(retry_manager),
  ).unwrap()
  let server2_provider = NativeQuicTlsProvider::new(
    server=true,
    allow_system_roots=false,
  )
  defer server2_provider.close()
  let server2 = @quic.QuicTlsDriver::new(server2_packets, server2_provider).unwrap()
  let queue : Array[(@quic.QuicDriverAction, Bool)] = []
  let mut dropped_replay = false
  for action in client_retry {
    match action {
      SendDatagram(_, _) if !dropped_replay => dropped_replay = true
      _ => queue.push((action, true))
    }
  }
  guard dropped_replay else {
    fail("expected to drop the first post-Retry Initial")
  }
  let timer_replay = client.poll(2000L).unwrap()
  guard timer_replay.any(fn(action) {
    match action {
      SendDatagram(_, _) => true
      _ => false
    }
  }) else {
    fail("expected timer-driven Initial replay")
  }
  for action in timer_replay {
    queue.push((action, true))
  }
  for action in server2.start({ ..server_options, alpn: ["h3"], }, 2L).unwrap() {
    queue.push((action, false))
  }
  let exchanged = exchange_quic_packets(client, server2, endpoint, queue, 2001L)
  match exchanged {
    Ok(_) => ()
    Err(error) => {
      match error {
        Tls(_) => println("Retry handshake error: TLS")
        InvalidPacket(_) => println("Retry handshake error: packet")
        Protocol(_, _) => println("Retry handshake error: protocol")
        Unsupported(_) => println("Retry handshake error: unsupported")
        AmplificationBlocked => println("Retry handshake error: amplification")
        LimitExceeded(name, value) =>
          println("Retry handshake error: limit \{name}=\{value}")
        _ => println("Retry handshake error: transport")
      }
      fail("Retry handshake did not complete")
    }
  }
  assert_eq(client.datagram_driver().state(), Established)
  assert_eq(server2.datagram_driver().state(), Established)
}
