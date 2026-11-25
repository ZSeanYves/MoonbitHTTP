///|
fn test_uri(value : String) -> @types.Uri {
  @types.Uri::parse(value).unwrap()
}

///|
async test "client: total deadline covers a blocked executor" {
  let defaults = @client.RequestOptions::defaults()
  let options = {
    ..defaults,
    timeouts: { ..defaults.timeouts, total_ms: Some(10), },
  }
  for internal_timeout in [false, true] {
    let exchange = async fn(_) {
      if internal_timeout {
        @async.with_timeout(1, async fn() { @async.sleep(60000) })
      } else {
        @async.sleep(60000)
      }
      fail("blocked exchange resumed")
    }
    @client.with_client(
      async fn(client) {
        let err : Error = try {
          ignore(
            client.send(
              client.request(
                Get,
                test_uri("http://example.test/"),
                @client.Upload::bytes(b""),
              ),
            ),
          )
          fail("send succeeded")
        } catch {
          error => error
        }
        if internal_timeout {
          assert_true(err is @async.TimeoutError)
        } else {
          assert_true(
            err is @client.ClientError::ClientTimeout(ClientTotal, 10L, 10L),
          )
        }
      },
      version=Http11,
      exchange~,
      options~,
      now_millis=() => 0L,
      wall_clock_seconds=() => 0L,
      authorize_redirect=(_, _) => Ok(()),
    )
  }
}

///|
async test "client: redirect policy is checked before the next request" {
  let defaults = @client.RequestOptions::defaults()
  let options = {
    ..defaults,
    redirect: @client.RedirectPolicy::limited(max_redirects=2).unwrap(),
  }
  let redirected : Array[String] = []

  let response_headers = @types.HeaderMap::new()
  response_headers
  .append_string("location", "http://blocked.test/next")
  .unwrap()
  let mut calls = 0
  let exchange = byte_peer(fn(_) {
    calls += 1
    Ok({ status: 302, version: Http11, headers: response_headers, body: b"", })
  })
  @client.with_client(
    async fn(client) {
      let request : @types.Request[Bytes] = {
        http_method: Get,
        uri: test_uri("http://example.test/"),
        version: Http11,
        headers: @types.HeaderMap::new(),
        body: b"",
      }
      assert_true(
        (Ok(send_bytes(client, request)) catch { error => Err(error) })
        is Err(@client.ClientError::ClientPolicy(Denied(Redirect, _))),
      )
      assert_eq(calls, 1)
      assert_eq(redirected, ["blocked.test:80"])
    },
    exchange~,
    version=Http11,
    wall_clock_seconds=() => 0L,
    options~,
    now_millis=fn() { 0L },
    authorize_redirect=fn(endpoint, operation) {
      redirected.push(endpoint.authority())
      if operation == Redirect {
        Err(Denied(Redirect, "redirect target denied"))
      } else {
        Ok(())
      }
    },
  )
}

///|
async test "client: request policy mutations do not alter caller headers" {
  let original = @types.HeaderMap::new()
  original.append_string("x-original", "yes").unwrap()
  let exchange = byte_peer(fn(request) {
    request.headers.append_string("x-executor", "mutated").unwrap()
    Ok({
      status: 200,
      version: Http11,
      headers: @types.HeaderMap::new(),
      body: b"ok",
    })
  })
  @client.with_client(
    async fn(client) {
      let response = send_bytes(client, {
        http_method: Get,
        uri: test_uri("http://example.test/"),
        version: Http11,
        headers: original,
        body: b"",
      })
      assert_eq(response.body, b"ok")
      assert_true(original.get_string("x-executor") is None)
      assert_eq(
        original.get_string("x-original").unwrap().to_string_lossy(),
        "yes",
      )
    },
    exchange~,
    version=Http11,
    wall_clock_seconds=() => 0L,
    authorize_redirect=fn(_, _) { Ok(()) },
    now_millis=fn() { 0L },
  )
}

///|
async test "client auth: Basic credentials are scoped to the configured origin" {
  let origin = test_uri("http://example.test/")
  let credentials = @auth.BasicCredentials::new("user", "password").unwrap()

  let seen : Array[String] = []
  let exchange = byte_peer(fn(request) {
    seen.push(
      request.headers.get_string("authorization").unwrap().to_string_lossy(),
    )
    Ok({
      status: 200,
      version: Http11,
      headers: @types.HeaderMap::new(),
      body: b"ok",
    })
  })
  @client.with_client(
    async fn(client) {
      client.set_basic_auth(origin, credentials).unwrap()

      let response = send_bytes(client, {
        http_method: Get,
        uri: origin,
        version: Http11,
        headers: @types.HeaderMap::new(),
        body: b"",
      })
      assert_eq(response.body, b"ok")
      assert_eq(seen, ["Basic dXNlcjpwYXNzd29yZA=="])
    },
    exchange~,
    version=Http11,
    wall_clock_seconds=() => 0L,
    authorize_redirect=fn(_, _) { Ok(()) },
    now_millis=fn() { 0L },
  )
}

///|
async test "client auth: Digest challenge is retried with a fresh authorization header" {
  let origin = test_uri("http://example.test/")
  let credentials = @auth.DigestCredentials::new("user", "password").unwrap()

  let mut calls = 0
  let seen : Array[String?] = []
  let exchange = byte_peer(fn(request) {
    calls += 1
    seen.push(
      match request.headers.get_string("authorization") {
        Some(value) => Some(value.to_string_lossy())
        None => None
      },
    )
    if calls == 1 {
      let headers = @types.HeaderMap::new()
      headers
      .append_string(
        "www-authenticate", "Digest realm=\"test\", nonce=\"nonce\", algorithm=SHA-256, qop=\"auth\"",
      )
      .unwrap()
      Ok({ status: 401, version: Http11, headers, body: b"", })
    } else {
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
      client
      .set_digest_auth(origin, credentials, fn() { Ok("cnonce") })
      .unwrap()

      let response = send_bytes(client, {
        http_method: Get,
        uri: origin,
        version: Http11,
        headers: @types.HeaderMap::new(),
        body: b"",
      })
      assert_eq(response.body, b"ok")
      assert_eq(calls, 2)
      assert_eq(seen[0], None)
      assert_true(seen[1] is Some(value) && value.has_prefix("Digest "))
    },
    exchange~,
    version=Http11,
    wall_clock_seconds=() => 0L,
    authorize_redirect=fn(_, _) { Ok(()) },
    now_millis=fn() { 0L },
  )
}

///|
async test "client: redirect renews the Digest challenge budget but counts toward retry limits" {
  let first = test_uri("https://first.test/")
  let second = test_uri("https://second.test/")
  let options = {
    ..@client.RequestOptions::defaults(),
    redirect: @client.RedirectPolicy::limited().unwrap(),
    retry: @client.RetryPolicy::idempotent(max_attempts=5).unwrap(),
  }

  let credentials = @auth.DigestCredentials::new("user", "password").unwrap()
  let seen : Array[(@types.Uri, Bool)] = []
  let exchange = byte_peer(request => {
    seen.push(
      (request.uri, request.headers.get_string("authorization") is Some(_)),
    )
    let headers = @types.HeaderMap::new()
    let status = match seen.length() {
      1 | 2 | 4 => {
        let attempt = seen.length()
        let stale = if attempt == 2 { ", stale=true" } else { "" }
        headers
        .append_string(
          "www-authenticate",
          "Digest realm=\"test\", nonce=\"n\{attempt}\", algorithm=SHA-256, qop=\"auth\"" +
          stale,
        )
        .unwrap()
        401
      }
      3 => {
        headers.append_string("location", second.value).unwrap()
        302
      }
      _ => 503
    }
    Ok({ status, version: Http11, headers, body: b"", })
  })
  @client.with_client(
    async fn(client) {
      for origin in [first, second] {
        client
        .set_digest_auth(origin, credentials, fn() { Ok("cnonce") })
        .unwrap()
      }

      let response = send_bytes(client, {
        http_method: Get,
        uri: first,
        version: Http11,
        headers: @types.HeaderMap::new(),
        body: b"",
      })
      assert_eq(response.status, 503)
      assert_eq(seen, [
        (first, false),
        (first, true),
        (first, true),
        (second, false),
        (second, true),
      ])
    },
    exchange~,
    version=Http11,
    wall_clock_seconds=() => 0L,
    options~,
    authorize_redirect=fn(_, _) { Ok(()) },
    now_millis=fn() { 0L },
    wait=_ => fail("all five attempts have already been used"),
  )
}

///|
async test "client auth: Digest does not replay an undeclared nonempty body" {
  let origin = test_uri("http://example.test/")
  let credentials = @auth.DigestCredentials::new("user", "password").unwrap()

  let mut calls = 0
  let exchange = byte_peer(fn(_) {
    calls += 1
    let headers = @types.HeaderMap::new()
    headers
    .append_string(
      "www-authenticate", "Digest realm=\"test\", nonce=\"nonce\", algorithm=SHA-256, qop=\"auth\"",
    )
    .unwrap()
    Ok({ status: 401, version: Http11, headers, body: b"", })
  })
  @client.with_client(
    async fn(client) {
      client
      .set_digest_auth(origin, credentials, fn() { Ok("cnonce") })
      .unwrap()

      let response = send_bytes(
        client,
        {
          http_method: Post,
          uri: origin,
          version: Http11,
          headers: @types.HeaderMap::new(),
          body: b"cannot replay",
        },
        once=true,
      )
      assert_eq(response.status, 401)
      assert_eq(calls, 1)
    },
    exchange~,
    version=Http11,
    wall_clock_seconds=() => 0L,
    authorize_redirect=fn(_, _) { Ok(()) },
    now_millis=fn() { 0L },
  )
}

///|
async test "client content coding: advertised gzip is decoded under the shared body limit" {
  let original = b"client response body"
  let encoded = @gzip.gzip_compress(original)
  let mut seen_encoding : String? = None
  let exchange = byte_peer(fn(request) {
    seen_encoding = match request.headers.get_string("accept-encoding") {
      Some(value) => Some(value.to_string_lossy())
      None => None
    }
    let headers = @types.HeaderMap::new()
    headers.append_string("content-encoding", "gzip").unwrap()
    headers
    .append_string("content-length", encoded.length().to_string())
    .unwrap()
    Ok({ status: 200, version: Http11, headers, body: encoded, })
  })
  @client.with_client(
    async fn(client) {
      let response = send_bytes(client, {
        http_method: Get,
        uri: test_uri("http://example.test/"),
        version: Http11,
        headers: @types.HeaderMap::new(),
        body: b"",
      })
      assert_eq(response.body, original)
      assert_eq(seen_encoding, Some("gzip, deflate, br"))
      assert_true(response.headers.get_string("content-encoding") is None)
    },
    exchange~,
    version=Http11,
    wall_clock_seconds=() => 0L,
    content_decoding=true,
    authorize_redirect=fn(_, _) { Ok(()) },
    now_millis=fn() { 0L },
  )
}
