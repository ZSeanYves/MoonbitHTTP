///|
async test "fresh conditional GET and HEAD reuse the cached validator locally" {
  let cache = @cache.HttpCache::new().unwrap()
  let request = pooled_request(
    "http://origin.test/document",
    @types.HeaderMap::new(),
  )
  let headers = @types.HeaderMap::new()
  headers.append_string("etag", "\"v1,fr\"").unwrap()
  headers.append_string("cache-control", "max-age=60").unwrap()
  headers.append_string("content-type", "text/plain").unwrap()
  ignore(
    cache
    .store(
      request.map_body(_ => ()),
      { status: 200, version: Http11, headers, body: (), },
      b"hello",
      0L,
    )
    .unwrap(),
  )
  let client = @client.Client::new(
    cache~,
    cache_enabled=true,
    authorize_redirect=(_, _) => Ok(()),
    now_millis=() => 0L,
  ).unwrap()
  let executor = @client.ClosureRoundTripper::new(_ => {
    fail("unexpected upstream request")
  })
  for http_method in [@types.Get, Head] {
    let fields = @types.HeaderMap::new()
    fields.append_string("if-none-match", "\"other\"").unwrap()
    fields.append_string("if-none-match", "W/\"v1,fr\"").unwrap()
    let response = client
      .send(executor, { ..request, http_method, headers: fields, }, 1L)
      .unwrap()
    assert_eq(response.status, 304)
    assert_eq(response.body, b"")
    assert_eq(
      response.headers.get_string("etag").unwrap().to_string_lossy(),
      "\"v1,fr\"",
    )
    assert_eq(
      response.headers.get_string("age").unwrap().to_string_lossy(),
      "1",
    )
    assert_true(response.headers.get_string("content-type") is None)
  }
  request.headers.append_string("if-none-match", "\"v2\"").unwrap()
  let response = client.send(executor, request, 1L).unwrap()
  assert_eq(response.status, 200)
  assert_eq(response.body, b"hello")
  headers.remove(@types.HeaderName::parse("etag").unwrap())
  ignore(
    cache
    .store(
      request.map_body(_ => ()),
      { status: 200, version: Http11, headers, body: (), },
      b"updated",
      2L,
    )
    .unwrap(),
  )
  let wildcard = @types.HeaderMap::new()
  wildcard.append_string("if-none-match", "*").unwrap()
  assert_eq(
    client.send(executor, { ..request, headers: wildcard, }, 3L).unwrap().status,
    304,
  )
}

///|
async test "redirects revalidate each resource with its own cache validator" {
  for cached_destination in [false, true] {
    let cache = @cache.HttpCache::new().unwrap()
    let from = pooled_request("http://origin.test/old", @types.HeaderMap::new())
    let to = pooled_request("http://origin.test/new", @types.HeaderMap::new())
    for (request, tag) in [(from, "\"old\""), (to, "\"new\"")] {
      if request.uri == to.uri && !cached_destination {
        continue
      }
      let headers = @types.HeaderMap::new()
      headers.append_string("cache-control", "max-age=0").unwrap()
      headers.append_string("etag", tag).unwrap()
      ignore(
        cache
        .store(
          request.map_body(_ => ()),
          { status: 200, version: Http11, headers, body: (), },
          b"cached",
          0L,
        )
        .unwrap(),
      )
    }
    let client = @client.Client::new(
      cache~,
      cache_enabled=true,
      options={
        ..@client.RequestOptions::defaults(),
        redirect: @client.RedirectPolicy::limited().unwrap(),
      },
      authorize_redirect=(_, _) => Ok(()),
      now_millis=() => 0L,
    ).unwrap()
    let seen : Array[String?] = []
    let executor = @client.ClosureRoundTripper::new(request => {
      seen.push(
        request.headers
        .get_string("if-none-match")
        .map(v => v.to_string_lossy()),
      )
      let headers = @types.HeaderMap::new()
      if request.uri == from.uri {
        headers.append_string("location", "/new").unwrap()
        Ok({ status: 302, version: Http11, headers, body: b"", })
      } else {
        assert_eq(request.uri, to.uri)
        if cached_destination {
          Ok({ status: 304, version: Http11, headers, body: b"", })
        } else {
          Ok({ status: 200, version: Http11, headers, body: b"new", })
        }
      }
    })
    let response = client.send(executor, from, 1L).unwrap()
    assert_eq(seen, [
      Some("\"old\""),
      if cached_destination {
        Some("\"new\"")
      } else {
        None
      },
    ])
    assert_eq(response.status, 200)
    assert_eq(
      response.body,
      if cached_destination {
        b"cached"
      } else {
        b"new"
      },
    )
  }
}
