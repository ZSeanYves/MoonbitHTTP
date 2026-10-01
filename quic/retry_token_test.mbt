///|
test "retry token binds endpoint, original DCID and both source CIDs" {
  let endpoint = @types.Endpoint::new("udp", "retry.example", 443).unwrap()
  let other_endpoint = @types.Endpoint::new("udp", "other.example", 443).unwrap()
  let original = @quic.ConnectionId::new(b"original-dcid").unwrap()
  let retry = @quic.ConnectionId::new(b"retry-scid").unwrap()
  let client = @quic.ConnectionId::new(b"client-scid").unwrap()
  let manager = @quic.QuicRetryTokenManager::new(
    b"01234567890123456789012345678901",
    lifetime_ms=100L,
  ).unwrap()
  let token = manager
    .issue(
      endpoint,
      original,
      retry,
      client,
      @test_support.FixedClock::new(10L, 0L),
      @test_support.ZeroEntropy::new(),
    )
    .unwrap()
  let context = manager.validate_initial(endpoint, token, 20L).unwrap()
  assert_true(
    @quic.QuicDatagramDriver::new(
      Server,
      endpoint,
      retry,
      retry,
      client,
      retry_context=Some(context),
      now_ms=20L,
    )
    is Ok(_),
  )
  assert_true(
    @quic.QuicDatagramDriver::new(
      Server,
      other_endpoint,
      retry,
      retry,
      client,
      retry_context=Some(context),
      now_ms=20L,
    )
    is Err(_),
  )
  assert_true(
    @quic.QuicDatagramDriver::new(
      Server,
      endpoint,
      retry,
      retry,
      original,
      retry_context=Some(context),
      now_ms=20L,
    )
    is Err(_),
  )
  assert_true(
    @quic.QuicDatagramDriver::new(
      Server,
      endpoint,
      original,
      retry,
      client,
      retry_context=Some(context),
      now_ms=20L,
    )
    is Err(_),
  )
  assert_true(
    @quic.QuicDatagramDriver::new(
      Server,
      endpoint,
      retry,
      original,
      client,
      retry_context=Some(context),
      now_ms=20L,
    )
    is Err(_),
  )
  assert_true(
    @quic.QuicDatagramDriver::new(
      Client,
      endpoint,
      retry,
      retry,
      client,
      retry_context=Some(context),
      now_ms=20L,
    )
    is Err(_),
  )
  assert_true(
    @quic.QuicDatagramDriver::new(
      Server,
      endpoint,
      retry,
      retry,
      client,
      retry_context=Some(context),
      now_ms=111L,
    )
    is Err(_),
  )
  assert_true(manager.validate_initial(other_endpoint, token, 20L) is Err(_))
  assert_true(manager.validate_initial(endpoint, token, 111L) is Err(_))
}

///|
test "retry token requires a 256 bit key and rejects tampering" {
  let endpoint = @types.Endpoint::new("udp", "retry.example", 443).unwrap()
  let original = @quic.ConnectionId::new(b"original-dcid").unwrap()
  let retry = @quic.ConnectionId::new(b"retry-scid").unwrap()
  let client = @quic.ConnectionId::new(b"client-scid").unwrap()
  assert_true(@quic.QuicRetryTokenManager::new(b"too-short") is Err(_))
  let manager = @quic.QuicRetryTokenManager::new(
    b"01234567890123456789012345678901",
  ).unwrap()
  let token = manager
    .issue(
      endpoint,
      original,
      retry,
      client,
      @test_support.FixedClock::new(10L, 0L),
      @test_support.ZeroEntropy::new(),
    )
    .unwrap()
  let bytes = token.to_array()
  bytes[bytes.length() - 1] = bytes[bytes.length() - 1] ^ 1
  assert_true(
    manager.validate_initial(endpoint, Bytes::from_array(bytes), 20L) is Err(_),
  )
}
