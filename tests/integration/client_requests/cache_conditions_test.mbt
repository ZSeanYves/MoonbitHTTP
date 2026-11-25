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
  let now = Ref(1L)
  let exchange = byte_peer(_ => fail("unexpected upstream request"))
  @client.with_client(
    async fn(client) {
      for http_method in [@types.Get, Head] {
        let fields = @types.HeaderMap::new()
        fields.append_string("if-none-match", "\"other\"").unwrap()
        fields.append_string("if-none-match", "W/\"v1,fr\"").unwrap()
        let response = send_bytes(client, {
          ..request,
          http_method,
          headers: fields,
        })
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
      let response = send_bytes(client, request)
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
        ({
          now.val = 3L
          send_bytes(client, { ..request, headers: wildcard, })
        }).status,
        304,
      )
    },
    exchange~,
    version=Http11,
    wall_clock_seconds=() => now.val,
    cache~,
    cache_enabled=true,
    authorize_redirect=(_, _) => Ok(()),
    now_millis=() => 0L,
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

    let seen : Array[String?] = []
    let exchange = byte_peer(request => {
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
    @client.with_client(
      async fn(client) {
        let response = send_bytes(client, from)
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
      },
      exchange~,
      version=Http11,
      wall_clock_seconds=() => 1L,
      cache~,
      cache_enabled=true,
      options={
        ..@client.RequestOptions::defaults(),
        redirect: @client.RedirectPolicy::limited().unwrap(),
      },
      authorize_redirect=(_, _) => Ok(()),
      now_millis=() => 0L,
    )
  }
}

///|
async test "an invalidated revalidation retries with the caller's original headers" {
  let uri = test_uri("http://example.test/item")
  for (once, repeated) in [(false, false), (true, false), (false, true)] {
    let cache = @cache.HttpCache::new().unwrap()
    let request : @types.Request[Unit] = {
      http_method: Get,
      uri,
      version: Http11,
      headers: @types.HeaderMap::new(),
      body: (),
    }
    let headers = @types.HeaderMap::new()
    headers.append_string("cache-control", "max-age=0").unwrap()
    headers.append_string("etag", "\"one\"").unwrap()
    ignore(
      cache
      .store(
        request,
        { status: 200, version: Http11, headers, body: (), },
        b"old",
        0L,
      )
      .unwrap(),
    )
    let mut calls = 0
    @client.with_client(
      async fn(client) {
        let upload = if once {
          @client.Upload::once(@body.EmptyBody::new())
        } else {
          @client.Upload::bytes(b"")
        }
        let req = client.request(Get, uri, upload)
        if once || repeated {
          try ignore(client.send(req)) catch {
            @client.ClientError::ClientProtocol(_) => ()
            e => raise e
          } noraise {
            _ => fail("invalid 304 was delivered")
          }
          assert_eq(calls, if once { 1 } else { 2 })
          return
        }
        let response = client.send(req)
        assert_eq(response.status, 200)
        assert_eq(@body.collect(response.body).0, b"fresh")
        assert_eq(calls, 2)
      },
      version=Http11,
      cache~,
      cache_enabled=true,
      now_millis=() => 1L,
      wall_clock_seconds=() => 1L,
      authorize_redirect=(_, _) => Ok(()),
      exchange=req => {
        calls += 1
        if calls == 2 {
          assert_true(req.headers.get_string("if-none-match") is None)
          return {
            status: if repeated {
              304
            } else {
              200
            },
            version: Http11,
            headers: @types.HeaderMap::new(),
            body: incoming(b"fresh"),
          }
        }
        assert_true(req.headers.get_string("if-none-match") is Some(_))
        cache.clear()
        {
          status: 304,
          version: Http11,
          headers: @types.HeaderMap::new(),
          body: incoming(b""),
        }
      },
    )
  }
}

///|
async test "SWR coalesces stale reads and refreshes within the window" {
  for status in [200, 304] {
    let now = Ref(0L)
    let calls = Ref(0)
    let started : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
    let release : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
    let cache = @cache.HttpCache::new().unwrap()
    let request = pooled_request(
      "http://origin.test/swr",
      @types.HeaderMap::new(),
    )
    let headers = @types.HeaderMap::new()
    headers.append_string("etag", "\"v1\"").unwrap()
    headers
    .append_string("cache-control", "max-age=1, stale-while-revalidate=30")
    .unwrap()
    cache
    .store(
      request.map_body(_ => ()),
      { status: 200, version: Http11, headers, body: (), },
      b"v1",
      0L,
    )
    .unwrap()
    |> ignore
    @client.with_client(
      async fn(client) {
        now.val = 2L
        let local_only = @types.HeaderMap::new()
        local_only.append_string("cache-control", "only-if-cached").unwrap()
        assert_eq(
          send_bytes(client, { ..request, headers: local_only, }).body,
          b"v1",
        )
        assert_eq(calls.val, 0)
        assert_eq(send_bytes(client, request).body, b"v1")
        @async.with_timeout(1000, () => started.get())
        now.val = 15L
        assert_eq(send_bytes(client, request).body, b"v1")
        assert_eq(calls.val, 1)
        release.put(())
        @async.with_timeout(1000, async fn() {
          while !(cache.lookup(request.map_body(_ => ()), now.val).unwrap()
                is CacheFresh(_)) {
            @async.pause()
          }
        })
        now.val = 40L
        assert_eq(
          send_bytes(client, request).body,
          if status == 200 {
            b"v2"
          } else {
            b"v1"
          },
        )
        assert_eq(calls.val, 1)
      },
      version=Http11,
      exchange=byte_peer(req => {
        calls.val += 1
        assert_eq(
          req.headers.get_string("if-none-match").unwrap().to_string_lossy(),
          "\"v1\"",
        )
        started.put(())
        release.get()
        let fields = @types.HeaderMap::new()
        fields.append_string("cache-control", "max-age=100").unwrap()
        fields
        .append_string("etag", if status == 200 { "\"v2\"" } else { "\"v1\"" })
        .unwrap()
        Ok({
          status,
          version: Http11,
          headers: fields,
          body: if status == 200 {
            b"v2"
          } else {
            b""
          },
        })
      }),
      cache~,
      cache_enabled=true,
      wall_clock_seconds=() => now.val,
      now_millis=() => 0L,
      authorize_redirect=(_, _) => Ok(()),
    )
  }
}
