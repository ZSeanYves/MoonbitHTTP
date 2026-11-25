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
