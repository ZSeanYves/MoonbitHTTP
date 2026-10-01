///|
fn cache_test_uri(path : String) -> @types.Uri {
  @types.Uri::parse("https://Example.test" + path).unwrap()
}

///|
fn cache_test_request(
  http_method_arg : @types.Method,
  path : String,
  headers? : @types.HeaderMap = @types.HeaderMap::new(),
) -> @types.Request[Unit] {
  {
    http_method: http_method_arg,
    uri: cache_test_uri(path),
    version: Http11,
    headers,
    body: (),
  }
}

///|
fn cache_test_response(
  status : Int,
  cache_control : String,
  body : Bytes,
  date_seconds : Int64,
  etag? : String? = None,
) -> @types.Response[Unit] {
  let headers = @types.HeaderMap::new()
  headers.append_string("cache-control", cache_control).unwrap()
  headers
  .append_string(
    "date",
    @types.HttpDate::from_unix_seconds(date_seconds).unwrap().format().unwrap(),
  )
  .unwrap()
  headers.append_string("content-length", body.length().to_string()).unwrap()
  match etag {
    Some(value) => headers.append_string("etag", value).unwrap()
    None => ()
  }
  { status, version: Http11, headers, body: (), }
}

///|
test "cache parser: directives, age, vary, and malformed values" {
  let headers = @types.HeaderMap::new()
  headers
  .append_string(
    "cache-control", "public, max-age=60, stale-while-revalidate=5, max-stale",
  )
  .unwrap()
  headers
  .append_string("vary", "Accept-Language, X-Mode, accept-language")
  .unwrap()
  headers.append_string("age", "3").unwrap()
  let control = @cache.parse_cache_control(headers).unwrap()
  assert_true(control.public)
  assert_eq(control.max_age, Some(60L))
  assert_eq(control.stale_while_revalidate, Some(5L))
  assert_true(control.max_stale_any)
  assert_eq(@cache.parse_age(headers).unwrap(), 3L)
  let (wildcard, vary) = @cache.parse_vary(headers).unwrap()
  assert_true(!wildcard)
  assert_eq(vary, ["accept-language", "x-mode"])
  let bad = @types.HeaderMap::new()
  bad.append_string("cache-control", "max-age=x").unwrap()
  assert_true(@cache.parse_cache_control(bad) is Err(InvalidCacheControl))
  let bad_age = @types.HeaderMap::new()
  bad_age.append_string("age", "1,2").unwrap()
  assert_true(@cache.parse_age(bad_age) is Err(InvalidAge))
  let bad_vary = @types.HeaderMap::new()
  bad_vary.append_string("vary", "x bad").unwrap()
  assert_true(@cache.parse_vary(bad_vary) is Err(InvalidVary))
}

///|
test "cache lookup: finite fresh entries and Vary isolation" {
  let cache = @cache.HttpCache::new().unwrap()
  let request_headers = @types.HeaderMap::new()
  request_headers.append_string("accept-language", "en").unwrap()
  let request = cache_test_request(Get, "/resource", headers=request_headers)
  let response = cache_test_response(200, "max-age=30", b"english", 100L)
  response.headers.append_string("vary", "Accept-Language").unwrap()
  assert_eq(
    cache.store(request, response, b"english", 100L).unwrap(),
    CacheStored,
  )
  match cache.lookup(request, 110L).unwrap() {
    CacheFresh(hit) => {
      assert_eq(hit.body(), b"english")
      assert_eq(hit.age_seconds(), 10L)
      assert_eq(hit.freshness_lifetime(), 30L)
    }
    _ => assert_true(false)
  }
  let other_headers = @types.HeaderMap::new()
  other_headers.append_string("accept-language", "fr").unwrap()
  let other = cache_test_request(Get, "/resource", headers=other_headers)
  match cache.lookup(other, 110L).unwrap() {
    CacheMiss => ()
    _ => assert_true(false)
  }
  let head = cache_test_request(Head, "/resource", headers=request.headers)
  match cache.lookup(head, 110L).unwrap() {
    CacheFresh(hit) => assert_eq(hit.body(), b"")
    _ => assert_true(false)
  }
}

///|
test "cache stale revalidation: validators, conditional headers, and 304 merge" {
  let cache = @cache.HttpCache::new().unwrap()
  let request = cache_test_request(Get, "/etag")
  let response = cache_test_response(
    200,
    "max-age=1",
    b"payload",
    100L,
    etag=Some("\"v1\""),
  )
  ignore(cache.store(request, response, b"payload", 100L).unwrap())
  match cache.lookup(request, 102L).unwrap() {
    CacheRevalidate(lookup) => {
      let conditional = @cache.conditional_request_headers(
        request.headers,
        lookup,
      )
      assert_eq(
        conditional.get_string("if-none-match").unwrap().to_string_lossy(),
        "\"v1\"",
      )
      assert_eq(@cache.etag_matches("W/\"v1\"", "\"v1\""), ConditionMatches)
      assert_eq(
        @cache.etag_matches("\"other\"", "\"v1\""),
        ConditionDoesNotMatch,
      )
      let not_modified_headers = @types.HeaderMap::new()
      not_modified_headers
      .append_string(
        "date",
        @types.HttpDate::from_unix_seconds(102L).unwrap().format().unwrap(),
      )
      .unwrap()
      not_modified_headers.append_string("cache-control", "max-age=30").unwrap()
      not_modified_headers.append_string("x-refresh", "yes").unwrap()
      let not_modified : @types.Response[Unit] = {
        status: 304,
        version: Http11,
        headers: not_modified_headers,
        body: (),
      }
      let refreshed = cache.revalidate(request, not_modified, 102L).unwrap()
      assert_eq(refreshed.body(), b"payload")
      assert_eq(refreshed.freshness_lifetime(), 30L)
      assert_eq(
        refreshed.response().headers
        .get_string("x-refresh")
        .unwrap()
        .to_string_lossy(),
        "yes",
      )
    }
    _ => assert_true(false)
  }
}

///|
test "cache policy: no-store, set-cookie, authorization, and only-if-cached" {
  let cache = @cache.HttpCache::new().unwrap()
  let request = cache_test_request(Get, "/private")
  let no_store = cache_test_response(200, "no-store, max-age=30", b"x", 1L)
  assert_true(
    cache.store(request, no_store, b"x", 1L).unwrap()
    is CacheNotStored(NotCacheable(_)),
  )
  let set_cookie = cache_test_response(200, "max-age=30", b"x", 1L)
  set_cookie.headers.append_string("set-cookie", "sid=secret").unwrap()
  assert_true(
    cache.store(request, set_cookie, b"x", 1L).unwrap()
    is CacheNotStored(NotCacheable(_)),
  )
  let only_headers = @types.HeaderMap::new()
  only_headers.append_string("cache-control", "only-if-cached").unwrap()
  let only = cache_test_request(Get, "/missing", headers=only_headers)
  match cache.lookup(only, 1L).unwrap() {
    OnlyIfCachedMiss => ()
    _ => assert_true(false)
  }
  let shared_config : @cache.CacheConfig = {
    ..@cache.CacheConfig::defaults(),
    shared: true,
  }
  let shared = @cache.HttpCache::new(config=shared_config).unwrap()
  let authorized_headers = @types.HeaderMap::new()
  authorized_headers.append_string("authorization", "Bearer secret").unwrap()
  let authorized = cache_test_request(
    Get,
    "/authorized",
    headers=authorized_headers,
  )
  let private = cache_test_response(200, "max-age=30", b"x", 1L)
  assert_true(
    shared.store(authorized, private, b"x", 1L).unwrap()
    is CacheNotStored(NotCacheable(_)),
  )
}

///|
test "cache limits: metadata/body bounds and deterministic eviction" {
  let limits : @cache.CacheLimits = {
    ..@cache.CacheLimits::defaults(),
    max_entries: 1,
    max_total_bytes: 8,
    max_entry_bytes: 8,
  }
  let cache = @cache.HttpCache::new(config={
    ..@cache.CacheConfig::defaults(),
    limits,
  }).unwrap()
  let first = cache_test_request(Get, "/one")
  let response = cache_test_response(200, "max-age=60", b"1234", 1L)
  assert_true(
    cache.store(first, response, b"1234", 1L).unwrap()
    is CacheNotStored(EntryTooLarge(_)),
  )
  let tiny_limits : @cache.CacheLimits = {
    ..@cache.CacheLimits::defaults(),
    max_entries: 1,
    max_total_bytes: 1024,
    max_entry_bytes: 1024,
  }
  let bounded = @cache.HttpCache::new(config={
    ..@cache.CacheConfig::defaults(),
    limits: tiny_limits,
  }).unwrap()
  let one = cache_test_request(Get, "/one")
  let two = cache_test_request(Get, "/two")
  ignore(
    bounded
    .store(one, cache_test_response(200, "max-age=60", b"1", 1L), b"1", 1L)
    .unwrap(),
  )
  ignore(
    bounded
    .store(two, cache_test_response(200, "max-age=60", b"2", 1L), b"2", 2L)
    .unwrap(),
  )
  assert_eq(bounded.len(), 1)
  match bounded.lookup(one, 2L).unwrap() {
    CacheMiss => ()
    _ => assert_true(false)
  }
  match bounded.lookup(two, 2L).unwrap() {
    CacheFresh(hit) => assert_eq(hit.body(), b"2")
    _ => assert_true(false)
  }
}

///|
test "cache invalidation: unsafe response clears related same-origin URIs" {
  let cache = @cache.HttpCache::new().unwrap()
  let target = cache_test_request(Get, "/target")
  let related = cache_test_request(Get, "/related")
  ignore(
    cache.store(
      target,
      cache_test_response(200, "max-age=60", b"target", 1L),
      b"target",
      1L,
    ),
  )
  ignore(
    cache.store(
      related,
      cache_test_response(200, "max-age=60", b"related", 1L),
      b"related",
      1L,
    ),
  )
  let location_headers = @types.HeaderMap::new()
  location_headers.append_string("location", "/related").unwrap()
  location_headers.append_string("content-location", "/target").unwrap()
  let mutation : @types.Request[Unit] = {
    http_method: Post,
    uri: cache_test_uri("/mutate"),
    version: Http11,
    headers: @types.HeaderMap::new(),
    body: (),
  }
  let response : @types.Response[Unit] = {
    status: 204,
    version: Http11,
    headers: location_headers,
    body: (),
  }
  cache.invalidate_response(mutation, response).unwrap()
  assert_true(cache.lookup(target, 2L).unwrap() is CacheMiss)
  assert_true(cache.lookup(related, 2L).unwrap() is CacheMiss)
}

///|
test "cache policy: must-revalidate disables stale-if-error fallback" {
  let cache = @cache.HttpCache::new().unwrap()
  let request = cache_test_request(Get, "/strict")
  let response = cache_test_response(
    200,
    "max-age=0, stale-if-error=60, must-revalidate",
    b"strict",
    1L,
    etag=Some("\"strict\""),
  )
  ignore(cache.store(request, response, b"strict", 1L).unwrap())
  match cache.lookup(request, 2L).unwrap() {
    CacheRevalidate(hit) => assert_eq(hit.stale_if_error(), 0L)
    _ => assert_true(false)
  }
}
