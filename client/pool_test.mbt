///|
test "client pool: keys isolate protocol and proxy identity" {
  let endpoint = @transport.Endpoint::new("https", "example.test", 443).unwrap()
  let first = @client.ConnectionKey::new(
    endpoint,
    None,
    Some("default"),
    Http2,
    None,
  )
  let second = @client.ConnectionKey::new(
    endpoint,
    Some("proxy-a"),
    Some("default"),
    Http2,
    None,
  )
  let third = @client.ConnectionKey::new(
    endpoint,
    None,
    Some("default"),
    Http1,
    None,
  )
  assert_true(first != second)
  assert_true(first != third)
  let proxy_a = @transport.Endpoint::new("http", "proxy-a.test", 8080).unwrap()
  let proxy_b = @transport.Endpoint::new("http", "proxy-b.test", 8080).unwrap()
  let via_a = @client.ConnectionKey::new(
    endpoint,
    Some("shared"),
    Some("default"),
    Http1,
    None,
    proxy_endpoint=Some(proxy_a),
  )
  let via_b = @client.ConnectionKey::new(
    endpoint,
    Some("shared"),
    Some("default"),
    Http1,
    None,
    proxy_endpoint=Some(proxy_b),
  )
  assert_true(via_a != via_b)
}

///|
test "client pool: bounded reuse and non-reusable eviction" {
  let limits : @client.PoolLimits = { max_total: 1, max_idle: 1, }
  let pool = @client.ConnectionPool::new(limits~).unwrap()
  let endpoint = @transport.Endpoint::new("http", "example.test", 80).unwrap()
  let key = @client.ConnectionKey::new(endpoint, None, None, Http1, None)
  let created = pool.acquire(key).unwrap()
  guard created is Created(id) else { fail("expected a new lease") }
  pool.release(id, true).unwrap()
  assert_eq(pool.idle_len(), 1)
  let reused = pool.acquire(key).unwrap()
  assert_true(reused is Reused(_))
  pool.release(id, false).unwrap()
  assert_eq(pool.len(), 0)
}

///|
test "client pool: leases reject double release and foreign keys" {
  let pool = @client.ConnectionPool::new().unwrap()
  let endpoint = @transport.Endpoint::new("http", "example.test", 80).unwrap()
  let key = @client.ConnectionKey::new(endpoint, None, None, Http1, None)
  let foreign = @client.ConnectionKey::new(
    endpoint,
    Some("proxy"),
    None,
    Http1,
    None,
  )
  let lease = pool.acquire_lease(key).unwrap()
  assert_eq(pool.remove(lease.id()), Err(LeaseInUse))
  let forged : @client.PoolLease = {
    key: foreign,
    id: lease.id(),
    released: false,
  }
  assert_eq(pool.release_lease(forged, true), Err(UnknownLease))
  pool.release_lease(lease, true).unwrap()
  assert_true(lease.is_released())
  assert_eq(pool.release_lease(lease, true), Err(LeaseAlreadyReleased))
}

///|
test "client pool: active capacity is bounded while idle entries are evicted" {
  let limits : @client.PoolLimits = { max_total: 2, max_idle: 1, }
  let pool = @client.ConnectionPool::new(limits~).unwrap()
  let endpoint = @transport.Endpoint::new("http", "example.test", 80).unwrap()
  let first = @client.ConnectionKey::new(endpoint, None, None, Http1, Some("a"))
  let second = @client.ConnectionKey::new(
    endpoint,
    None,
    None,
    Http1,
    Some("b"),
  )
  let third = @client.ConnectionKey::new(endpoint, None, None, Http1, Some("c"))
  let one = pool.acquire_lease(first).unwrap()
  let two = pool.acquire_lease(second).unwrap()
  assert_true(pool.acquire(third) is Err(AtCapacity))
  pool.release_lease(one, true).unwrap()
  assert_eq(pool.idle_len(), 1)
  pool.release_lease(two, true).unwrap()
  assert_eq(pool.idle_len(), 1)
  assert_eq(pool.len(), 1)
}

///|
test "client pool: a new key evicts the LRU idle entry and reports its ID" {
  let limits : @client.PoolLimits = { max_total: 1, max_idle: 1, }
  let pool = @client.ConnectionPool::new(limits~).unwrap()
  let endpoint = @transport.Endpoint::new("http", "example.test", 80).unwrap()
  let first = @client.ConnectionKey::new(
    endpoint,
    None,
    None,
    Http1,
    Some("first"),
  )
  let second = @client.ConnectionKey::new(
    endpoint,
    None,
    None,
    Http1,
    Some("second"),
  )
  let first_lease = pool.acquire_lease(first).unwrap()
  let first_id = first_lease.id()
  pool.release_lease(first_lease, true).unwrap()
  let second_lease = pool.acquire_lease(second).unwrap()
  assert_eq(pool.take_evicted_ids(), [first_id])
  assert_eq(pool.take_evicted_ids(), [])
  pool.release_lease(second_lease, false).unwrap()
  assert_eq(pool.take_evicted_ids(), [second_lease.id()])
}

///|
test "client pool: eviction notifications are bounded until drained" {
  let limits : @client.PoolLimits = { max_total: 1, max_idle: 1, }
  let pool = @client.ConnectionPool::new(limits~).unwrap()
  let endpoint = @transport.Endpoint::new("http", "example.test", 80).unwrap()
  let first = @client.ConnectionKey::new(
    endpoint,
    None,
    None,
    Http1,
    Some("first"),
  )
  let second = @client.ConnectionKey::new(
    endpoint,
    None,
    None,
    Http1,
    Some("second"),
  )
  let first_lease = pool.acquire_lease(first).unwrap()
  let first_id = first_lease.id()
  pool.release_lease(first_lease, true).unwrap()
  let second_lease = pool.acquire_lease(second).unwrap()
  assert_eq(pool.evicted_len(), 1)
  assert_eq(pool.release_lease(second_lease, false), Err(AtCapacity))
  assert_eq(pool.evicted_len(), 1)
  assert_eq(pool.len(), 1)
  assert_eq(pool.take_evicted_ids(), [first_id])
  pool.release_lease(second_lease, false).unwrap()
  assert_eq(pool.take_evicted_ids(), [second_lease.id()])
}
