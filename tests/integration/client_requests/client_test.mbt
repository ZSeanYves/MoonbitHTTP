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
  let client = @client.Client::new(
    options~,
    authorize_redirect=fn(_, _) { Ok(()) },
    now_millis=fn() { 0L },
  ).unwrap()
  let executor = @client.ClosureRoundTripper::new(async fn(_) {
    @async.sleep(60_000)
    Err(ClientProtocol("blocked executor unexpectedly resumed"))
  })
  let request : @types.Request[Bytes] = {
    http_method: Get,
    uri: test_uri("http://example.test/"),
    version: Http11,
    headers: @types.HeaderMap::new(),
    body: b"",
  }
  assert_true(
    client.send(executor, request, 0L)
    is Err(ClientTimeout(ClientTotal, 10L, 10L)),
  )
  let inner_error : Error = @async.with_timeout(1, async fn() {
    @async.sleep(60000)
    fail("inner deadline did not expire")
  }) catch {
    error => error
  }
  let already_timed_out = @client.ClosureRoundTripper::new(_ => {
    raise inner_error
  })
  let inner_timeout = try {
    ignore(client.send(already_timed_out, request, 0L))
    false
  } catch {
    @async.TimeoutError => true
    error => raise error
  }
  assert_true(inner_timeout)
}

///|
async test "client: redirect policy is checked before the next request" {
  let defaults = @client.RequestOptions::defaults()
  let options = {
    ..defaults,
    redirect: @client.RedirectPolicy::limited(max_redirects=2).unwrap(),
  }
  let redirected : Array[String] = []
  let client = @client.Client::new(options~, now_millis=fn() { 0L }, authorize_redirect=fn(
    endpoint,
    operation,
  ) {
    redirected.push(endpoint.authority())
    if operation == Redirect {
      Err(Denied(Redirect, "redirect target denied"))
    } else {
      Ok(())
    }
  }).unwrap()
  let response_headers = @types.HeaderMap::new()
  response_headers
  .append_string("location", "http://blocked.test/next")
  .unwrap()
  let mut calls = 0
  let executor = @client.ClosureRoundTripper::new(fn(_) {
    calls += 1
    Ok({ status: 302, version: Http11, headers: response_headers, body: b"", })
  })
  let request : @types.Request[Bytes] = {
    http_method: Get,
    uri: test_uri("http://example.test/"),
    version: Http11,
    headers: @types.HeaderMap::new(),
    body: b"",
  }
  assert_true(
    client.send(executor, request, 0L) is Err(ClientPolicy(Denied(Redirect, _))),
  )
  assert_eq(calls, 1)
  assert_eq(redirected, ["blocked.test:80"])
}

///|
async test "client: request policy mutations do not alter caller headers" {
  let original = @types.HeaderMap::new()
  original.append_string("x-original", "yes").unwrap()
  let executor = @client.ClosureRoundTripper::new(fn(request) {
    request.headers.append_string("x-executor", "mutated").unwrap()
    Ok({
      status: 200,
      version: Http11,
      headers: @types.HeaderMap::new(),
      body: b"ok",
    })
  })
  let client = @client.Client::new(authorize_redirect=fn(_, _) { Ok(()) }, now_millis=fn() {
    0L
  }).unwrap()
  let response = client
    .send(
      executor,
      {
        http_method: Get,
        uri: test_uri("http://example.test/"),
        version: Http11,
        headers: original,
        body: b"",
      },
      0L,
    )
    .unwrap()
  assert_eq(response.body, b"ok")
  assert_true(original.get_string("x-executor") is None)
  assert_eq(original.get_string("x-original").unwrap().to_string_lossy(), "yes")
}

///|
async test "client auth: Basic credentials are scoped to the configured origin" {
  let origin = test_uri("http://example.test/")
  let credentials = @auth.BasicCredentials::new("user", "password").unwrap()
  let client = @client.Client::new(authorize_redirect=fn(_, _) { Ok(()) }, now_millis=fn() {
    0L
  }).unwrap()
  client.set_basic_auth(origin, credentials).unwrap()
  let seen : Array[String] = []
  let executor = @client.ClosureRoundTripper::new(fn(request) {
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
  let response = client
    .send(
      executor,
      {
        http_method: Get,
        uri: origin,
        version: Http11,
        headers: @types.HeaderMap::new(),
        body: b"",
      },
      0L,
    )
    .unwrap()
  assert_eq(response.body, b"ok")
  assert_eq(seen, ["Basic dXNlcjpwYXNzd29yZA=="])
}

///|
async test "client auth: Digest challenge is retried with a fresh authorization header" {
  let origin = test_uri("http://example.test/")
  let credentials = @auth.DigestCredentials::new("user", "password").unwrap()
  let client = @client.Client::new(authorize_redirect=fn(_, _) { Ok(()) }, now_millis=fn() {
    0L
  }).unwrap()
  client.set_digest_auth(origin, credentials, fn() { Ok("cnonce") }).unwrap()
  let mut calls = 0
  let seen : Array[String?] = []
  let executor = @client.ClosureRoundTripper::new(fn(request) {
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
  let response = client
    .send(
      executor,
      {
        http_method: Get,
        uri: origin,
        version: Http11,
        headers: @types.HeaderMap::new(),
        body: b"",
      },
      0L,
    )
    .unwrap()
  assert_eq(response.body, b"ok")
  assert_eq(calls, 2)
  assert_eq(seen[0], None)
  assert_true(seen[1] is Some(value) && value.has_prefix("Digest "))
}

///|
async test "client auth: Digest does not replay an undeclared nonempty body" {
  let origin = test_uri("http://example.test/")
  let credentials = @auth.DigestCredentials::new("user", "password").unwrap()
  let client = @client.Client::new(authorize_redirect=fn(_, _) { Ok(()) }, now_millis=fn() {
    0L
  }).unwrap()
  client.set_digest_auth(origin, credentials, fn() { Ok("cnonce") }).unwrap()
  let mut calls = 0
  let executor = @client.ClosureRoundTripper::new(fn(_) {
    calls += 1
    let headers = @types.HeaderMap::new()
    headers
    .append_string(
      "www-authenticate", "Digest realm=\"test\", nonce=\"nonce\", algorithm=SHA-256, qop=\"auth\"",
    )
    .unwrap()
    Ok({ status: 401, version: Http11, headers, body: b"", })
  })
  let response = client
    .send(
      executor,
      {
        http_method: Post,
        uri: origin,
        version: Http11,
        headers: @types.HeaderMap::new(),
        body: b"cannot replay",
      },
      0L,
    )
    .unwrap()
  assert_eq(response.status, 401)
  assert_eq(calls, 1)
}

///|
async test "client content coding: advertised gzip is decoded under the shared body limit" {
  let original = b"client response body"
  let encoded = @gzip.gzip_compress(original)
  let mut seen_encoding : String? = None
  let executor = @client.ClosureRoundTripper::new(fn(request) {
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
  let client = @client.Client::new(
    content_decoding=true,
    authorize_redirect=fn(_, _) { Ok(()) },
    now_millis=fn() { 0L },
  ).unwrap()
  let response = client
    .send(
      executor,
      {
        http_method: Get,
        uri: test_uri("http://example.test/"),
        version: Http11,
        headers: @types.HeaderMap::new(),
        body: b"",
      },
      0L,
    )
    .unwrap()
  assert_eq(response.body, original)
  assert_eq(seen_encoding, Some("gzip, deflate, br"))
  assert_true(response.headers.get_string("content-encoding") is None)
}
