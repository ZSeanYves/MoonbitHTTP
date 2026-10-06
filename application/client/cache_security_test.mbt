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
      let client = @client.Client::new(
        cache~,
        cache_enabled=true,
        authorize_redirect=fn(_, _) { Ok(()) },
        now_millis=fn() { 0L },
      ).unwrap()
      let executor = @client.ClosureRoundTripper::new(sent => {
        assert_true(sent.headers.get_string("if-none-match") is Some(_))
        if transport_failure {
          Err(ClientProtocol("network unavailable"))
        } else {
          Ok({
            status: 503,
            version: Http11,
            headers: @types.HeaderMap::new(),
            body: b"unavailable",
          })
        }
      })
      let result = client.send(
        executor,
        {
          http_method: request.http_method,
          uri: request.uri,
          version: request.version,
          headers: request.headers,
          body: b"",
        },
        0L,
      )
      if control == "max-age=0, stale-if-error=30" {
        assert_eq(result.unwrap().body, b"old")
      } else if transport_failure {
        assert_true(result is Err(_))
      } else {
        assert_eq(result.unwrap().status, 503)
      }
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
  let client = @client.Client::new(
    cache~,
    cache_enabled=true,
    authorize_redirect=fn(_, _) { Ok(()) },
    now_millis=fn() { 0L },
  ).unwrap()
  let executor = @client.ClosureRoundTripper::new(fn(_) {
    let headers = @types.HeaderMap::new()
    headers.append_string("etag", "\"new\"").unwrap()
    headers.append_string("cache-control", "max-age=60").unwrap()
    Ok({ status: 304, version: Http11, headers, body: b"", })
  })
  request.headers.append_string("if-none-match", "\"new\"").unwrap()
  let response = client
    .send(
      executor,
      {
        http_method: request.http_method,
        uri: request.uri,
        version: request.version,
        headers: request.headers,
        body: b"",
      },
      1L,
    )
    .unwrap()
  assert_eq(response.status, 304)
  assert_eq(response.body, b"")
  guard cache.lookup(request, 2L).unwrap() is CacheRevalidate(hit) else {
    fail("unrelated 304 refreshed cache")
  }
  assert_eq(hit.etag(), Some("\"old\""))
}
