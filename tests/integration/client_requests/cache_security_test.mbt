///|
async test "security: cache fallback covers transport errors and 5xx with explicit permission" {
  for
    control in [
      "max-age=0", "no-cache, max-age=60, stale-if-error=30", "must-revalidate, max-age=0, stale-if-error=30",
      "max-age=0, stale-if-error=30",
    ] {
    for transport_failure in [true, false] {
      let cache = @cache.HttpCache::new().unwrap()
      let headers = @types.HeaderMap::new()
      headers.append_string("cache-control", control).unwrap()
      headers.append_string("etag", "\"old\"").unwrap()
      let request : @types.Request[Unit] = {
        http_method: Get,
        uri: test_uri("http://example.test/cached"),
        version: Http11,
        headers: @types.HeaderMap::new(),
        body: (),
      }
      cache
      .store(
        request,
        { status: 200, version: Http11, headers, body: (), },
        b"old",
        0L,
      )
      .unwrap()
      |> ignore
      let delays : Array[Int64] = []
      let exchange = byte_peer(sent => {
        assert_true(sent.headers.get_string("if-none-match") is Some(_))
        if transport_failure {
          Err(ClientTransport(Closed))
        } else {
          Ok({
            status: 503,
            version: Http11,
            headers: @types.HeaderMap::new(),
            body: b"unavailable",
          })
        }
      })
      @client.with_client(
        async fn(client) {
          let result = Ok(
            send_bytes(client, {
              http_method: request.http_method,
              uri: request.uri,
              version: request.version,
              headers: request.headers,
              body: b"",
            }),
          ) catch {
            error => Err(error)
          }
          let allows_fallback = control == "max-age=0, stale-if-error=30"
          // A transport failure can use the fallback immediately. A 503 first
          // uses the configured retry, even when the cached response is eligible.
          assert_eq(
            delays,
            if transport_failure && allows_fallback {
              []
            } else {
              [25L]
            },
          )
          if allows_fallback {
            assert_eq(result.unwrap().body, b"old")
          } else if transport_failure {
            assert_true(result is Err(_))
          } else {
            assert_eq(result.unwrap().status, 503)
          }
        },
        exchange~,
        version=Http11,
        wall_clock_seconds=() => 0L,
        options={
          ..@client.RequestOptions::defaults(),
          retry: @client.RetryPolicy::idempotent(
            max_attempts=2,
            base_delay_ms=25L,
          ).unwrap(),
        },
        wait=delay => delays.push(delay),
        cache~,
        cache_enabled=true,
        authorize_redirect=fn(_, _) { Ok(()) },
        now_millis=fn() { 0L },
      )
    }
  }
}

///|
async test "security: caller validators cannot revalidate a different cached body" {
  let cache = @cache.HttpCache::new().unwrap()
  let headers = @types.HeaderMap::new()
  headers.append_string("cache-control", "max-age=0").unwrap()
  headers.append_string("etag", "\"old\"").unwrap()
  let request : @types.Request[Unit] = {
    http_method: Get,
    uri: test_uri("http://example.test/cached"),
    version: Http11,
    headers: @types.HeaderMap::new(),
    body: (),
  }
  cache
  .store(
    request,
    { status: 200, version: Http11, headers, body: (), },
    b"old",
    0L,
  )
  .unwrap()
  |> ignore
  let exchange = byte_peer(fn(_) {
    let headers = @types.HeaderMap::new()
    headers.append_string("etag", "\"new\"").unwrap()
    headers.append_string("cache-control", "max-age=60").unwrap()
    Ok({ status: 304, version: Http11, headers, body: b"", })
  })
  @client.with_client(
    async fn(client) {
      request.headers.append_string("if-none-match", "\"new\"").unwrap()
      let response = send_bytes(client, {
        http_method: request.http_method,
        uri: request.uri,
        version: request.version,
        headers: request.headers,
        body: b"",
      })
      assert_eq(response.status, 304)
      assert_eq(response.body, b"")
      guard cache.lookup(request, 2L).unwrap() is CacheRevalidate(hit) else {
        fail("unrelated 304 refreshed cache")
      }
      assert_eq(hit.etag(), Some("\"old\""))
    },
    exchange~,
    version=Http11,
    wall_clock_seconds=() => 1L,
    cache~,
    cache_enabled=true,
    authorize_redirect=fn(_, _) { Ok(()) },
    now_millis=fn() { 0L },
  )
}

///|
async test "cache-only misses never open an upstream connection" {
  let cache = @cache.HttpCache::new().unwrap()

  let headers = @types.HeaderMap::new()
  headers.append_string("cache-control", "only-if-cached").unwrap()
  let mut calls = 0
  let now = Ref(1L)
  let exchange = byte_peer(fn(_) {
    calls += 1
    Ok({
      status: 200,
      version: Http11,
      headers: @types.HeaderMap::new(),
      body: b"origin",
    })
  })
  @client.with_client(
    async fn(client) {
      let request : @types.Request[Bytes] = {
        http_method: Get,
        uri: test_uri("http://example.test/read"),
        version: Http11,
        headers,
        body: b"",
      }
      assert_eq(send_bytes(client, request).status, 504)
      let stored = @types.HeaderMap::new()
      stored.append_string("etag", "\"stale\"").unwrap()
      stored.append_string("cache-control", "max-age=1").unwrap()
      ignore(
        cache
        .store(
          request.map_body(_ => ()),
          { status: 200, version: Http11, headers: stored, body: (), },
          b"cached",
          1L,
        )
        .unwrap(),
      )
      assert_eq(send_bytes(client, request).body, b"cached")
      assert_eq(
        ({
          now.val = 3L
          send_bytes(client, request)
        }).status,
        504,
      )
      assert_eq(calls, 0)
    },
    exchange~,
    version=Http11,
    wall_clock_seconds=() => now.val,
    cache~,
    cache_enabled=true,
    authorize_redirect=fn(_, _) { Ok(()) },
    now_millis=fn() { 0L },
  )
}
