///|
test "quic path manager: validates challenge before migration" {
  let first = @types.Endpoint::new("udp", "one.example", 443).unwrap()
  let second = @types.Endpoint::new("udp", "two.example", 443).unwrap()
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

///|
test "quic connection IDs: retire prior to compacts authenticated history" {
  let initial = @quic.ConnectionId::new(b"initial").unwrap()
  let manager = @quic.QuicConnectionIdManager::new(initial, max_active=2).unwrap()
  for sequence in 1L..<80L {
    let id = @quic.ConnectionId::new(
      @utf8.encode("cid-" + sequence.to_string()),
    ).unwrap()
    manager
    .receive(
      sequence,
      sequence,
      id,
      Bytes::from_array(FixedArray::make(16, sequence.to_byte())),
    )
    .unwrap()
    assert_true(manager.active().length() <= 2)
  }
  // The compacted prefix is still protected by RETIRE_PRIOR_TO and cannot be
  // reintroduced after its bookkeeping has been discarded.
  assert_true(
    manager.receive(
      1L,
      79L,
      @quic.ConnectionId::new(b"reused").unwrap(),
      Bytes::from_array(FixedArray::make(16, b'\x07')),
    )
    is Err(_),
  )
}

///|
test "quic connection IDs: duplicate announcements still advance retire prior to" {
  let initial = @quic.ConnectionId::new(b"initial").unwrap()
  let manager = @quic.QuicConnectionIdManager::new(initial, max_active=2).unwrap()
  let token = Bytes::from_array(FixedArray::make(16, b'\x01'))
  let next = @quic.ConnectionId::new(b"next").unwrap()
  manager.receive(1L, 0L, next, token).unwrap()
  assert_eq(manager.active().length(), 2)

  // The same authenticated sequence is idempotent, but its newer floor still
  // retires and compacts the older sequence.
  manager.receive(1L, 1L, next, token).unwrap()
  assert_eq(manager.active().length(), 1)
  // Reordered announcements below the retirement floor are ignored by the
  // manager; the datagram driver responds by retiring them again.
  assert_eq(manager.receive(0L, 0L, initial, token), Ok(()))
  assert_eq(manager.active().length(), 1)

  let later = @quic.ConnectionId::new(b"later").unwrap()
  manager.receive(2L, 1L, later, token).unwrap()
  assert_eq(manager.active().length(), 2)
}

///|
test "quic connection IDs: rejected operations preserve active state and bound tombstones" {
  let initial = @quic.ConnectionId::new(b"initial").unwrap()
  let manager = @quic.QuicConnectionIdManager::new(initial, max_active=2).unwrap()
  assert_true(manager.retire(0L) is Err(_))
  assert_eq(manager.active()[0].id(), initial)
  let next = @quic.ConnectionId::new(b"next").unwrap()
  let token = Bytes::from_array(FixedArray::make(16, b'\x01'))
  manager.receive(1L, 0L, next, token).unwrap()
  let before = manager.active()
  assert_true(manager.receive(1L, 1L, initial, token) is Err(_))
  assert_eq(manager.active(), before)
  manager.retire(1L).unwrap()
  for sequence in 2L..<200L {
    assert_true(
      manager.receive(
        sequence,
        0L,
        @quic.ConnectionId::new(b"later").unwrap(),
        Bytes::from_array(FixedArray::make(16, b'\x02')),
      )
      is Err(LimitExceeded("connection ID history", 2)),
    )
  }
  assert_eq(manager.active().length(), 1)
  manager
  .receive(
    2L,
    2L,
    @quic.ConnectionId::new(b"later").unwrap(),
    Bytes::from_array(FixedArray::make(16, b'\x02')),
  )
  .unwrap()
  assert_eq(manager.active()[0].sequence(), 2L)
}
