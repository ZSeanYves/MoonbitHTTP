///|
test "security: cache control scans supplementary characters at ASCII boundaries" {
  for
    value in [
      "x=😀, max-age=60", "x=\"😀,\\\"inside\", max-age=60", "😀, max-age=60",
    ] {
    let headers = @types.HeaderMap::new()
    headers.append_string("cache-control", value).unwrap()
    assert_eq(@cache.parse_cache_control(headers).unwrap().max_age, Some(60L))
  }
  let bad = @types.HeaderMap::new()
  bad.append_string("cache-control", "max-age=😀").unwrap()
  assert_true(@cache.parse_cache_control(bad) is Err(InvalidCacheControl))
}

///|
test "security: partial and HEAD responses never replace a complete GET" {
  let cache = @cache.HttpCache::new().unwrap()
  let request = cache_test_request(Get, "/complete")
  let complete = cache_test_response(200, "max-age=60", b"whole", 0L)
  cache.store(request, complete, b"whole", 0L).unwrap() |> ignore
  for status in [206, 304] {
    let response = cache_test_response(status, "max-age=60", b"x", 0L)
    assert_true(
      cache.store(request, response, b"x", 0L).unwrap() is CacheNotStored(_),
    )
  }
  let head = { ..request, http_method: Head, }
  assert_true(
    cache
    .store(head, cache_test_response(200, "max-age=60", b"", 0L), b"", 0L)
    .unwrap()
    is CacheNotStored(_),
  )
  let headers = @types.HeaderMap::new()
  headers.append_string("content-range", "bytes 0-0/5").unwrap()
  headers.append_string("cache-control", "max-age=60").unwrap()
  assert_true(
    cache
    .store(
      request,
      { status: 200, version: Http11, headers, body: (), },
      b"x",
      0L,
    )
    .unwrap()
    is CacheNotStored(_),
  )
  guard cache.lookup(request, 1L).unwrap() is CacheFresh(hit) else {
    fail("lost complete entry")
  }
  assert_eq(hit.body(), b"whole")
  guard cache.lookup(head, 1L).unwrap() is CacheFresh(hit) else {
    fail("HEAD lookup")
  }
  assert_eq(hit.body(), b"")
  for name in ["range", "if-range"] {
    let request_headers = @types.HeaderMap::new()
    request_headers.append_string(name, "bytes=0-0").unwrap()
    let ranged = { ..request, headers: request_headers, }
    assert_true(cache.lookup(ranged, 1L).unwrap() is CacheMiss)
    assert_true(
      cache.store(ranged, complete, b"whole", 1L).unwrap() is CacheNotStored(_),
    )
    request_headers.append_string("cache-control", "only-if-cached").unwrap()
    assert_true(cache.lookup(ranged, 1L).unwrap() is OnlyIfCachedMiss)
  }
}

///|
test "security: error fallback requires explicit permission even at zero stale age" {
  for
    control in [
      "max-age=0", "no-cache, max-age=60, stale-if-error=30", "must-revalidate, max-age=0, stale-if-error=30",
      "proxy-revalidate, max-age=0, stale-if-error=30",
    ] {
    let cache = @cache.HttpCache::new().unwrap()
    let request = cache_test_request(Get, "/strict")
    cache
    .store(
      request,
      cache_test_response(200, control, b"old", 0L, etag=Some("\"one\"")),
      b"old",
      0L,
    )
    .unwrap()
    |> ignore
    guard cache.lookup(request, 0L).unwrap() is CacheRevalidate(hit) else {
      fail("revalidation required")
    }
    assert_false(hit.allows_stale_if_error())
  }
  let cache = @cache.HttpCache::new().unwrap()
  let request = cache_test_request(Get, "/allowed")
  cache
  .store(
    request,
    cache_test_response(
      200,
      "max-age=0, stale-if-error=30",
      b"old",
      0L,
      etag=Some("\"one\""),
    ),
    b"old",
    0L,
  )
  .unwrap()
  |> ignore
  guard cache.lookup(request, 1L).unwrap() is CacheRevalidate(hit) else {
    fail("conditional")
  }
  assert_true(hit.allows_stale_if_error())
  guard cache.lookup(request, 31L).unwrap() is CacheRevalidate(expired) else {
    fail("conditional")
  }
  assert_false(expired.allows_stale_if_error())
  for control in ["no-cache", "max-age=0"] {
    let headers = @types.HeaderMap::new()
    headers.append_string("cache-control", control).unwrap()
    guard cache.lookup({ ..request, headers, }, 1L).unwrap()
      is CacheRevalidate(strict) else {
      fail("conditional")
    }
    assert_false(strict.allows_stale_if_error())
  }
}

///|
test "security: 304 binds the outgoing condition and returned validators" {
  let cache = @cache.HttpCache::new().unwrap()
  let request = cache_test_request(Get, "/validator")
  cache
  .store(
    request,
    cache_test_response(200, "max-age=0", b"old", 0L, etag=Some("\"old\"")),
    b"old",
    0L,
  )
  .unwrap()
  |> ignore
  let headers = @types.HeaderMap::new()
  headers.append_string("cache-control", "max-age=60").unwrap()
  let reply : @types.Response[Unit] = {
    status: 304,
    version: Http11,
    headers,
    body: (),
  }
  assert_true(cache.revalidate(request, reply, 1L) is Err(InvalidValidator))
  for tag in ["\"other\"", "*", "\"old\", \"other\""] {
    let conditional = @types.HeaderMap::new()
    conditional.append_string("if-none-match", tag).unwrap()
    assert_true(
      cache.revalidate({ ..request, headers: conditional, }, reply, 1L)
      is Err(InvalidValidator),
    )
  }
  let conditional = @types.HeaderMap::new()
  conditional.append_string("if-none-match", "W/\"old\"").unwrap()
  headers.append_string("etag", "\"new\"").unwrap()
  assert_true(
    cache.revalidate({ ..request, headers: conditional, }, reply, 1L)
    is Err(InvalidValidator),
  )
  headers.remove(@types.HeaderName::parse("etag").unwrap())
  let refreshed = cache
    .revalidate(
      { ..request, http_method: Head, headers: conditional, },
      reply,
      1L,
    )
    .unwrap()
  assert_eq(refreshed.body(), b"")
  guard cache.lookup(request, 2L).unwrap() is CacheFresh(hit) else {
    fail("GET lost after HEAD revalidation")
  }
  assert_eq(hit.body(), b"old")
  assert_eq(hit.etag(), Some("\"old\""))
}
