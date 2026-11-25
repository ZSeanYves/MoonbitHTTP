///|
fn incoming(bytes : Bytes) -> @client.IncomingBody {
  @client.IncomingBody::wrap(@body.FullBody::new(bytes))
}

///|
async test "HTTP/3 retries a rejected request and preserves unrelated stream errors" {
  for
    (cause, retry) in [
      (@client.ClientError::ClientH3Rejected(4L), true),
      (ClientHttp3(Goaway(4L)), true),
      (ClientHttp3(PeerReset(0L, 0x10cL)), false),
    ] {
    let mut calls = 0
    @client.with_client(
      async fn(client) {
        let req = client.request(
          Get,
          test_uri("https://example.test/"),
          @client.Upload::bytes(b""),
        )
        try {
          let res = client.send(req)
          assert_true(retry)
          assert_eq(@body.collect(res.body).0, b"ok")
        } catch {
          @client.ClientError::ClientHttp3(PeerReset(0L, 0x10cL)) =>
            assert_false(retry)
          error => raise error
        }
        assert_eq(calls, if retry { 2 } else { 1 })
      },
      version=Http3,
      options={
        ..@client.RequestOptions::defaults(),
        retry: @client.RetryPolicy::idempotent(max_attempts=2, base_delay_ms=0L).unwrap(),
      },
      now_millis=() => 0L,
      wall_clock_seconds=() => 0L,
      authorize_redirect=(_, _) => Ok(()),
      exchange=req => {
        calls += 1
        if calls == 1 {
          raise cause
        }
        {
          status: 200,
          version: req.version,
          headers: @types.HeaderMap::new(),
          body: incoming(b"ok"),
        }
      },
    )
  }
}

///|
async test "once and reopen uploads distinguish a preserving redirect from a rewrite" {
  for status in [303, 307, 308] {
    for replay in [true, false] {
      let mut calls = 0
      let mut opens = 0
      let mut discarded = 0
      @client.with_client(
        async fn(client) {
          let upload = if replay {
            @client.Upload::reopen(() => {
              opens += 1
              @body.FullBody::new(b"post")
            })
          } else {
            @client.Upload::once(@body.FullBody::new(b"post"))
          }
          let req = client.request(
            Post,
            test_uri("http://a.test/begin"),
            upload,
          )
          try {
            let res = client.send(req)
            assert_true(replay || status == 303)
            assert_eq(@body.collect(res.body).0, b"ok")
          } catch {
            @client.ClientError::ClientRedirect(RedirectBodyNotReplayable) =>
              assert_true(!replay && status != 303)
            err => raise err
          }
        },
        version=Http11,
        authorize_redirect=(_, _) => Ok(()),
        wall_clock_seconds=() => 0L,
        now_millis=() => 0L,
        options={
          ..@client.RequestOptions::defaults(),
          redirect: @client.RedirectPolicy::limited().unwrap(),
        },
        exchange=async fn(req) {
          calls += 1
          let data = @body.collect(req.body).0
          if calls == 1 {
            assert_eq(data, b"post")
            let headers = @types.HeaderMap::new()
            headers.append_string("location", "/end").unwrap()
            let old = @body.BodyStream::from_pull(
              () => fail("redirect body was drained"),
              on_cancel=_ => discarded += 1,
            )
            {
              status,
              version: Http11,
              headers,
              body: @client.IncomingBody::wrap(old),
            }
          } else {
            assert_eq(discarded, 1)
            assert_eq(data, if status == 303 { b"" } else { b"post" })
            {
              status: 200,
              version: Http11,
              headers: @types.HeaderMap::new(),
              body: incoming(b"ok"),
            }
          }
        },
      )
      assert_eq(discarded, 1)
      assert_eq(calls, if replay || status == 303 { 2 } else { 1 })
      assert_eq(opens, if !replay { 0 } else if status == 303 { 1 } else { 2 })
    }
  }
}

///|
async test "local responses and version rejection never open a factory and release an unused producer" {
  let uri = test_uri("http://origin.test/cache")
  let headers = @types.HeaderMap::new()
  headers.append_string("cache-control", "only-if-cached").unwrap()
  let mut cancelled = 0
  @client.with_client(
    async fn(client) {
      let factory = @client.Upload::reopen(() => {
        (fail("opened local request") : @body.FullBody)
      })
      let req = client.request(Get, uri, factory, headers~)
      assert_eq(client.send(req).status, 504)
      let once = @client.Upload::once(
        @body.BodyStream::from_pull(() => fail("read local request"), on_cancel=_ => {
          cancelled += 1
        }),
      )
      assert_eq(client.send({ ..req, body: once, }).status, 504)
      assert_eq(cancelled, 1)
      try ignore(client.send({ ..req, version: Http3, })) catch {
        @client.ClientError::ClientInvalidOptions(_) => ()
        err => raise err
      } noraise {
        _ => fail("version mismatch accepted")
      }
    },
    version=Http11,
    cache_enabled=true,
    exchange=_ => fail("unexpected exchange"),
    authorize_redirect=(_, _) => Ok(()),
    wall_clock_seconds=() => 0L,
    now_millis=() => 0L,
  )
}

///|
async test "unread and blocked response bodies expire and close their source once" {
  for read_now in [false, true] {
    let mut closed = 0
    let options = @client.RequestOptions::defaults()
    @client.with_client(
      async fn(client) {
        let res = client.send(
          client.request(
            Get,
            test_uri("http://origin.test/"),
            @client.Upload::bytes(b""),
          ),
        )
        if !read_now {
          @async.sleep(75)
        }
        try ignore(res.body.next_frame()) catch {
          @client.ClientError::ClientTimeout(ClientTotal, _, _) => ()
          err => raise err
        } noraise {
          _ => fail("deadline did not cancel the body")
        }
        res.body.cancel(@body.BodyError::Cancelled)
        assert_eq(closed, 1)
      },
      version=Http11,
      options={
        ..options,
        timeouts: { ..options.timeouts, total_ms: Some(30), },
      },
      wall_clock_seconds=() => 0L,
      now_millis=() => 0L,
      authorize_redirect=(_, _) => Ok(()),
      exchange=fn(req) {
        let source = @body.BodyStream::from_pull(
          async fn() {
            @async.sleep(60000)
            None
          },
          on_cancel=_ => closed += 1,
        )
        {
          status: 200,
          version: req.version,
          headers: @types.HeaderMap::new(),
          body: @client.IncomingBody::wrap(source),
        }
      },
    )
  }
}

///|
async test "cache commits the encoded representation and trailers only after clean consumption" {
  let uri = test_uri("http://origin.test/cached")
  let encoded = @gzip.gzip_compress(b"hello")
  let headers = @types.HeaderMap::new()
  headers.append_string("content-encoding", "gzip").unwrap()
  headers.append_string("cache-control", "max-age=60").unwrap()
  let tail = @types.HeaderMap::new()
  tail.append_string("x-trailer", "done").unwrap()
  let mut sent = 0
  @client.with_client(
    async fn(client) {
      let get = client.request(Get, uri, @client.Upload::bytes(b""))
      let first = client.send(get)
      assert_eq(first.headers.get_string("content-encoding"), None)
      assert_eq(client.cache().len(), 0)
      let (data, trailers) = @body.collect(first.body)
      assert_eq(data, b"hello")
      assert_true(trailers.unwrap().get_string("x-trailer") is Some(_))
      assert_eq(client.cache().len(), 1)
      client.set_content_decoding(false)
      let hit = client.send(get)
      assert_true(hit.headers.get_string("content-encoding") is Some(_))
      let (raw, stored_tail) = @body.collect(hit.body)
      assert_eq(raw, encoded)
      assert_true(stored_tail.unwrap().get_string("x-trailer") is Some(_))
      let head = client.send({ ..get, http_method: Head, })
      assert_true(head.body.next_frame() is None)
      assert_eq(sent, 1)
      client.cache().clear()
      let interrupted = client.send(get)
      ignore(interrupted.body.next_frame())
      interrupted.body.cancel(@body.BodyError::Cancelled)
      assert_eq(client.cache().len(), 0)
      let obsolete = client.send(get)
      ignore(obsolete.body.next_frame())
      let mutation = client.send(
        client.request(Post, uri, @client.Upload::bytes(b"")),
      )
      ignore(@body.collect(mutation.body))
      ignore(@body.collect(obsolete.body))
      assert_eq(client.cache().len(), 0)
    },
    version=Http2,
    cache_enabled=true,
    content_decoding=true,
    now_millis=() => 0L,
    wall_clock_seconds=() => 0L,
    authorize_redirect=(_, _) => Ok(()),
    exchange=req => {
      sent += 1
      if req.http_method == Post {
        {
          status: 204,
          version: Http2,
          headers: @types.HeaderMap::new(),
          body: incoming(b""),
        }
      } else {
        {
          status: 200,
          version: Http2,
          headers,
          body: @client.IncomingBody::wrap(
            @body.QueueBody::new([Data(encoded), Trailers(tail)]),
          ),
        }
      }
    },
  )
}

///|
async test "Digest auth-int verifies the exact entity and trailer before returning" {
  for valid in [true, false] {
    let uri = test_uri("https://example.com/upload")
    let mut calls = 0
    let mut opens = 0
    @client.with_client(
      async fn(client) {
        client
        .set_digest_auth(
          uri,
          @auth.DigestCredentials::new("user", "password").unwrap(),
          () => Ok("cnonce"),
        )
        .unwrap()
        let req = client.request(
          Post,
          uri,
          @client.Upload::reopen(() => {
            opens += 1
            @body.FullBody::new(b"request body")
          }),
        )
        try {
          let response = client.send(req)
          assert_true(valid)
          let (verified, trailers) = @body.collect(response.body)
          assert_eq(verified, b"response body")
          assert_true(
            trailers.unwrap().get_string("authentication-info") is Some(_),
          )
        } catch {
          @client.ClientError::ClientAuth(DigestResponseAuthMismatch) =>
            assert_false(valid)
          err => raise err
        }
        assert_eq(calls, 2)
        assert_eq(opens, 2)
      },
      version=Http3,
      now_millis=() => 0L,
      wall_clock_seconds=() => 0L,
      authorize_redirect=(_, _) => Ok(()),
      exchange=async fn(req) {
        calls += 1
        let headers = @types.HeaderMap::new()
        assert_eq(@body.collect(req.body).0, b"request body")
        if calls == 1 {
          headers
          .append_string(
            "www-authenticate", "Digest realm=\"r\", nonce=\"n\", qop=\"auth-int\", algorithm=SHA-256",
          )
          .unwrap()
          { status: 401, version: Http3, headers, body: incoming(b""), }
        } else {
          let tail = @types.HeaderMap::new()
          tail
          .append_string(
            "authentication-info", "rspauth=\"10673ef43d15cdbcdbeabb81104d11bc8042725b25dc89b3dc63fc7d17fc3198\", cnonce=\"cnonce\", nc=00000001, qop=auth-int",
          )
          .unwrap()
          let bytes = if valid { b"response body" } else { b"changed" }
          {
            status: 200,
            version: Http3,
            headers,
            body: @client.IncomingBody::wrap(
              @body.QueueBody::new([Data(bytes), Trailers(tail)]),
            ),
          }
        }
      },
    )
  }
}

///|
async test "leaving a client scope releases an unread response and its unfinished upload" {
  let mut uploads = 0
  let mut responses = 0
  let body = @client.with_client(
    async fn(client) {
      let source = @body.BodyStream::from_pull(
        () => fail("unexpected upload read"),
        on_cancel=_ => uploads += 1,
      )
      client.send(
        client.request(
          Post,
          test_uri("http://example.test/"),
          @client.Upload::once(source),
        ),
      ).body
    },
    version=Http2,
    exchange=req => {
      let source = @body.BodyStream::from_pull(
        () => fail("unexpected response read"),
        on_cancel=_ => responses += 1,
      )
      {
        status: 413,
        version: req.version,
        headers: @types.HeaderMap::new(),
        body: @client.IncomingBody::wrap(source),
      }
    },
    now_millis=() => 0L,
    wall_clock_seconds=() => 0L,
    authorize_redirect=(_, _) => Ok(()),
  )
  try ignore(body.next_frame()) catch {
    @client.ClientError::ClientCancelled(_) => ()
    error => raise error
  } noraise {
    _ => fail("body outlived its client scope")
  }
  body.cancel(@body.BodyError::Cancelled)
  assert_eq((uploads, responses), (1, 1))
}

///|
async test "oversized cache fills pass through and decoding failures discard the entry" {
  let defaults = @cache.CacheConfig::defaults()
  let cache = @cache.HttpCache::new(config={
    ..defaults,
    limits: { ..defaults.limits, max_entry_bytes: 4, },
  }).unwrap()
  let headers = @types.HeaderMap::new()
  headers.append_string("cache-control", "max-age=60").unwrap()
  let mut calls = 0
  @client.with_client(
    async fn(client) {
      let req = client.request(
        Get,
        test_uri("http://example.test/"),
        @client.Upload::bytes(b""),
      )
      assert_eq(@body.collect(client.send(req).body).0, b"12345")
      assert_eq(cache.len(), 0)
      headers.append_string("content-encoding", "gzip").unwrap()
      let broken = client.send(req)
      try ignore(@body.collect(broken.body)) catch {
        @content_coding.ContentCodingError::TruncatedEncodedBody(_)
        | @content_coding.ContentCodingError::InvalidEncodedBody(_) => ()
        error => raise error
      } noraise {
        _ => fail("malformed representation completed")
      }
      assert_eq(calls, 2)
      assert_eq(cache.len(), 0)
    },
    version=Http3,
    cache~,
    cache_enabled=true,
    content_decoding=true,
    now_millis=() => 0L,
    wall_clock_seconds=() => 0L,
    authorize_redirect=(_, _) => Ok(()),
    exchange=req => {
      calls += 1
      {
        status: 200,
        version: req.version,
        headers,
        body: incoming(if calls == 1 { b"12345" } else { b"bad" }),
      }
    },
  )
}
