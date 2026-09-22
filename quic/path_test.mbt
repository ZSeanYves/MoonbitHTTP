///|
test "quic path manager: validates challenge before migration" {
  let first = @transport.Endpoint::new("udp", "one.example", 443).unwrap()
  let second = @transport.Endpoint::new("udp", "two.example", 443).unwrap()
  let paths = @quic.QuicPathManager::new(first)
  assert_true(paths.begin(second, b"short") is Err(_))
  paths.begin(second, b"12345678").unwrap()
  assert_eq(paths.status(), PathChallenging)
  assert_true(paths.on_response(second, b"badbad!!") is Err(_))
  paths.abandon()
  paths.begin(second, b"12345678").unwrap()
  paths.on_response(second, b"12345678").unwrap()
  assert_eq(paths.active(), second)
  assert_eq(paths.status(), PathValidated)
  assert_eq(paths.generation(), 1L)
}

///|
test "quic connection IDs: reject reuse and preserve an active path" {
  let initial = @quic.ConnectionId::new(b"initial").unwrap()
  let manager = @quic.QuicConnectionIdManager::new(initial, max_active=2).unwrap()
  let next = @quic.ConnectionId::new(b"next").unwrap()
  manager
  .receive(1L, 0L, next, Bytes::from_array(FixedArray::make(16, b'\x01')))
  .unwrap()
  assert_eq(manager.active().length(), 2)
  assert_true(
    manager.receive(
      1L,
      0L,
      initial,
      Bytes::from_array(FixedArray::make(16, b'\x02')),
    )
    is Err(_),
  )
  manager.retire(1L).unwrap()
  assert_eq(manager.active().length(), 1)
}
