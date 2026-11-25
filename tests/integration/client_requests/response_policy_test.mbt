///|
async test "content decoding preserves representation metadata on bodyless responses" {
  let request = pooled_request(
    "http://origin.test/document",
    @types.HeaderMap::new(),
  )
  for (http_method, status) in [(@types.Head, 200), (Get, 304)] {
    let headers = @types.HeaderMap::new()
    headers.append_string("content-encoding", "gzip").unwrap()
    headers.append_string("content-length", "42").unwrap()
    let exchange = byte_peer(_ => {
      Ok({ status, version: Http11, headers, body: b"", })
    })
    @client.with_client(
      async fn(client) {
        let response = send_bytes(client, { ..request, http_method, })
        assert_eq(response.status, status)
        assert_eq(response.body, b"")
        assert_eq(
          response.headers
          .get_string("content-encoding")
          .unwrap()
          .to_string_lossy(),
          "gzip",
        )
        assert_eq(response.headers.content_length().unwrap(), Some(42))
      },
      exchange~,
      version=Http11,
      wall_clock_seconds=() => 0L,
      content_decoding=true,
      authorize_redirect=(_, _) => Ok(()),
      now_millis=() => 0L,
    )
  }
}

///|
async test "idempotent retry handles only HTTP/2 refused streams" {
  let request = pooled_request(
    "http://origin.test/document",
    @types.HeaderMap::new(),
  )
  for
    (http_method, code, retry) in [
      (@types.Get, @http2.RefusedStream, true),
      (Post, RefusedStream, false),
      (Get, ProtocolError, false),
    ] {
    let mut calls = 0
    let exchange = byte_peer(_ => {
      calls += 1
      if calls == 1 {
        Err(ClientHttp2(StreamError(1, code, "closed stream")))
      } else {
        Ok({
          status: 200,
          version: Http2,
          headers: @types.HeaderMap::new(),
          body: b"ok",
        })
      }
    })
    @client.with_client(
      async fn(client) {
        let result = Ok(send_bytes(client, { ..request, http_method, })) catch {
          error => Err(error)
        }
        if retry {
          assert_eq(calls, 2)
          assert_eq(result.unwrap().body, b"ok")
        } else {
          assert_eq(calls, 1)
          assert_true(
            result
            is Err(@client.ClientError::ClientHttp2(StreamError(1, actual, _))) &&
            actual == code,
          )
        }
      },
      exchange~,
      version=Http11,
      wall_clock_seconds=() => 0L,
      options={
        ..@client.RequestOptions::defaults(),
        retry: @client.RetryPolicy::idempotent(max_attempts=2).unwrap(),
      },
      wait=_ => (),
      authorize_redirect=(_, _) => Ok(()),
      now_millis=() => 0L,
    )
  }
}

///|
async test "retry refreshes jar cookies and respects a caller Cookie" {
  for explicit in [false, true] {
    let request = pooled_request(
      "http://origin.test/doc",
      @types.HeaderMap::new(),
    )
    if explicit {
      request.headers.append_string("cookie", "color=caller").unwrap()
    }
    let seen : Array[String] = []
    let exchange = byte_peer(sent => {
      seen.push(sent.headers.get_string("cookie").unwrap().to_string_lossy())
      let headers = @types.HeaderMap::new()
      let status = if seen.length() == 1 {
        headers.append_string("set-cookie", "color=blue; Path=/").unwrap()
        503
      } else {
        200
      }
      Ok({ status, version: Http11, headers, body: b"", })
    })
    @client.with_client(
      async fn(client) {
        let jar = client.cookie_jar()
        jar.set_enabled(true)
        ignore(jar.store_string("color=red; Path=/", request.uri, 0L).unwrap())

        assert_eq(send_bytes(client, request).status, 200)
        assert_eq(
          seen,
          if explicit {
            ["color=caller", "color=caller"]
          } else {
            ["color=red", "color=blue"]
          },
        )
      },
      exchange~,
      version=Http11,
      wall_clock_seconds=() => 0L,
      options={
        ..@client.RequestOptions::defaults(),
        retry: @client.RetryPolicy::idempotent(max_attempts=2).unwrap(),
      },
      wait=_ => (),
      authorize_redirect=(_, _) => Ok(()),
      now_millis=() => 0L,
    )
  }
}

///|
async test "Digest retry carries cookies from the challenge" {
  let origin = test_uri("http://example.test/")
  let credentials = @auth.DigestCredentials::new("user", "password").unwrap()

  for (explicit, once) in [(false, false), (true, false), (false, true)] {
    let mut calls = 0
    let seen : Array[String?] = []
    let exchange = byte_peer(request => {
      calls += 1
      seen.push(
        match request.headers.get_string("authorization") {
          Some(value) => Some(value.to_string_lossy())
          None => None
        },
      )
      if calls == 1 {
        let headers = @types.HeaderMap::new()
        headers.append_string("set-cookie", "round=one; Path=/").unwrap()
        headers.append_string("set-cookie", "second=two; Path=/").unwrap()
        headers
        .append_string(
          "www-authenticate", "Digest realm=\"test\", nonce=\"nonce\", algorithm=SHA-256, qop=\"auth\"",
        )
        .unwrap()
        Ok({ status: 401, version: Http11, headers, body: b"", })
      } else {
        assert_eq(
          request.headers.get_string("cookie").unwrap().to_string_lossy(),
          if explicit {
            "manual=yes"
          } else {
            "round=one; second=two"
          },
        )
        Ok({
          status: 200,
          version: Http11,
          headers: @types.HeaderMap::new(),
          body: b"ok",
        })
      }
    })
    @client.with_client(
      async fn(client) {
        client.cookie_jar().set_enabled(true)
        client
        .set_digest_auth(origin, credentials, fn() { Ok("cnonce") })
        .unwrap()

        let headers = @types.HeaderMap::new()
        if explicit {
          headers.append_string("cookie", "manual=yes").unwrap()
        }
        let upload = if once {
          @client.Upload::once(@body.EmptyBody::new())
        } else {
          @client.Upload::bytes(b"")
        }
        let response = client.send(
          client.request(Get, origin, upload, headers~),
        )
        assert_eq(client.cookie_jar().size(), 2)
        assert_eq(seen[0], None)
        if once {
          assert_eq(response.status, 401)
          assert_eq(calls, 1)
          return
        }
        assert_eq(@body.collect(response.body).0, b"ok")
        assert_eq(calls, 2)
        assert_true(seen[1] is Some(value) && value.has_prefix("Digest "))
      },
      exchange~,
      version=Http11,
      wall_clock_seconds=() => 0L,
      authorize_redirect=fn(_, _) { Ok(()) },
      now_millis=fn() { 0L },
    )
  }
}
