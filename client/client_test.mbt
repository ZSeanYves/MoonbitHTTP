///|
fn test_uri(value : String) -> @types.Uri {
  @types.Uri::parse(value).unwrap()
}

///|
fn test_request_headers() -> @types.HeaderMap {
  let headers = @types.HeaderMap::new()
  headers.append_string("Host", "old.example").unwrap()
  headers.append_string("Authorization", "Bearer secret").unwrap()
  headers.append_string("Cookie", "session=secret").unwrap()
  headers.append_string("Proxy-Authorization", "Basic secret").unwrap()
  headers.append_string("Content-Length", "7").unwrap()
  headers.append_string("Content-Type", "text/plain").unwrap()
  headers.append_string("Expect", "100-continue").unwrap()
  headers.append_string("X-Request-Id", "stable").unwrap()
  headers
}

///|
test "client endpoint: accepts only credential-free absolute HTTP URLs" {
  let endpoint = @client.ClientEndpoint::from_uri(
    test_uri("HTTPS://Example.COM/resource?q=1"),
  ).unwrap()
  assert_true(endpoint.secure)
  assert_eq(endpoint.origin, "https://example.com:443")
  assert_eq(endpoint.transport.host, "example.com")
  assert_true(
    @client.ClientEndpoint::from_uri(test_uri("ftp://example.com/file"))
    is Err(_),
  )
  assert_true(
    @client.ClientEndpoint::from_uri(test_uri("https://user@example.com/"))
    is Err(_),
  )
  assert_true(
    @client.ClientEndpoint::from_uri(test_uri("https://example.com/#fragment"))
    is Err(_),
  )
  assert_true(@client.ClientEndpoint::from_uri(test_uri("/relative")) is Err(_))
}

///|
test "client endpoint: normalizes default ports and host case for origins" {
  let first = @client.ClientEndpoint::from_uri(
    test_uri("https://EXAMPLE.com/path"),
  ).unwrap()
  let second = @client.ClientEndpoint::from_uri(
    test_uri("https://example.COM:443/other"),
  ).unwrap()
  assert_true(first.same_origin(second))
  let ipv6 = @client.ClientEndpoint::from_uri(test_uri("http://[2001:DB8::1]/")).unwrap()
  assert_eq(ipv6.origin, "http://[2001:db8::1]:80")
}

///|
test "client options: defaults are finite and unsafe opt-ins are rejected" {
  let options = @client.RequestOptions::defaults()
  assert_eq(options.timeouts.resolve_ms, Some(10000))
  assert_eq(options.timeouts.connect_ms, Some(10000))
  assert_eq(options.timeouts.total_ms, Some(120000))
  assert_eq(options.redirect, @client.RedirectPolicy::disabled())
  assert_eq(options.retry, @client.RetryPolicy::disabled())
  assert_eq(options.validate(), Ok(()))
  let no_total_timeout = {
    ..options,
    timeouts: { ..options.timeouts, total_ms: None, },
  }
  assert_eq(no_total_timeout.validate(), Ok(()))
  let invalid_timeout = {
    ..options,
    timeouts: { ..options.timeouts, connect_ms: Some(0), },
  }
  assert_true(invalid_timeout.validate() is Err(ClientInvalidOptions(_)))
  let unsafe_early_data = { ..options, allow_early_data: true, }
  assert_true(unsafe_early_data.validate() is Err(ClientInvalidOptions(_)))
  let safe_early_data = {
    ..unsafe_early_data,
    explicitly_idempotent: true,
    body_replayability: ReplayableBody,
  }
  assert_eq(safe_early_data.validate(), Ok(()))
}

///|
test "client: default TLS options are constructible before an endpoint is known" {
  let client = @client.Client::new().unwrap()
  assert_eq(client.tls().verify_peer, true)
  assert_true(client.tls().server_name is None)
}

///|
async test "client: total deadline covers a blocked executor" {
  let defaults = @client.RequestOptions::defaults()
  let options = {
    ..defaults,
    timeouts: { ..defaults.timeouts, total_ms: Some(10), },
  }
  let client = @client.Client::new(options~).unwrap()
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
}

///|
async test "client: redirect policy is checked before the next request" {
  let defaults = @client.RequestOptions::defaults()
  let options = {
    ..defaults,
    redirect: @client.RedirectPolicy::limited(max_redirects=2).unwrap(),
  }
  let redirected : Array[String] = []
  let client = @client.Client::new(options~, authorize_redirect=fn(
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
  let client = @client.Client::new().unwrap()
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
test "redirect: POST rewrite removes authority, credentials, and body metadata" {
  let initial = test_uri("https://example.com/start")
  let tracker = @client.RedirectTracker::new(
    initial,
    @client.RedirectPolicy::limited(max_redirects=3).unwrap(),
  ).unwrap()
  let decision = tracker
    .follow(
      initial,
      "/next",
      302,
      Post,
      test_request_headers(),
      NonReplayableBody,
    )
    .unwrap()
  assert_eq(decision.uri.value, "https://example.com/next")
  assert_eq(decision.http_method, Get)
  assert_true(decision.drop_body)
  assert_true(!decision.cross_origin)
  assert_true(decision.headers.get_string("host") is None)
  assert_true(decision.headers.get_string("cookie") is None)
  assert_true(decision.headers.get_string("proxy-authorization") is None)
  assert_true(decision.headers.get_string("content-length") is None)
  assert_true(decision.headers.get_string("content-type") is None)
  assert_true(decision.headers.get_string("expect") is None)
  assert_eq(
    decision.headers.get_string("authorization").unwrap().to_string_lossy(),
    "Bearer secret",
  )
  assert_eq(
    decision.headers.get_string("x-request-id").unwrap().to_string_lossy(),
    "stable",
  )
}

///|
test "redirect: cross-origin hops strip authorization and preserve safe fields" {
  let initial = test_uri("https://example.com/start")
  let tracker = @client.RedirectTracker::new(
    initial,
    @client.RedirectPolicy::limited(max_redirects=3).unwrap(),
  ).unwrap()
  let decision = tracker
    .follow(
      initial,
      "https://other.example/next",
      307,
      Get,
      test_request_headers(),
      ReplayNotRequired,
    )
    .unwrap()
  assert_true(decision.cross_origin)
  assert_eq(decision.http_method, Get)
  assert_true(!decision.drop_body)
  assert_true(decision.headers.get_string("authorization") is None)
  assert_eq(
    decision.headers.get_string("content-length").unwrap().to_string_lossy(),
    "7",
  )
}

///|
test "redirect: non-replayable bodies are rejected for every preserved method" {
  let initial = test_uri("https://example.com/start")
  let tracker = @client.RedirectTracker::new(
    initial,
    @client.RedirectPolicy::limited(max_redirects=3).unwrap(),
  ).unwrap()
  assert_true(
    tracker.follow(
      initial,
      "/next",
      308,
      Extension("UPLOAD"),
      @types.HeaderMap::new(),
      NonReplayableBody,
    )
    is Err(RedirectBodyNotReplayable),
  )
  let rewritten = tracker
    .follow(
      initial,
      "/accepted",
      303,
      Extension("UPLOAD"),
      @types.HeaderMap::new(),
      NonReplayableBody,
    )
    .unwrap()
  assert_eq(rewritten.http_method, Get)
  assert_true(rewritten.drop_body)
}

///|
test "redirect: downgrade, loops, limits, and disabled policy fail closed" {
  let initial = test_uri("https://example.com/start")
  let tracker = @client.RedirectTracker::new(
    initial,
    @client.RedirectPolicy::limited(max_redirects=1).unwrap(),
  ).unwrap()
  assert_true(
    tracker.follow(
      initial,
      "http://example.com/insecure",
      301,
      Get,
      @types.HeaderMap::new(),
      ReplayNotRequired,
    )
    is Err(RedirectDowngradeDenied),
  )
  let next = tracker
    .follow(
      initial,
      "/next",
      301,
      Get,
      @types.HeaderMap::new(),
      ReplayNotRequired,
    )
    .unwrap()
  assert_true(
    tracker.follow(
      next.uri,
      "/start",
      301,
      Get,
      @types.HeaderMap::new(),
      ReplayNotRequired,
    )
    is Err(RedirectLimitExceeded(1)),
  )
  let disabled = @client.RedirectTracker::new(
    initial,
    @client.RedirectPolicy::disabled(),
  ).unwrap()
  assert_true(
    disabled.follow(
      initial,
      "/next",
      301,
      Get,
      @types.HeaderMap::new(),
      ReplayNotRequired,
    )
    is Err(RedirectDisabled),
  )
}

///|
test "redirect: loop detection uses normalized origins" {
  let initial = test_uri("https://EXAMPLE.com:443/start")
  let tracker = @client.RedirectTracker::new(
    initial,
    @client.RedirectPolicy::limited(max_redirects=4).unwrap(),
  ).unwrap()
  let next = tracker
    .follow(
      initial,
      "/next",
      301,
      Get,
      @types.HeaderMap::new(),
      ReplayNotRequired,
    )
    .unwrap()
  assert_true(
    tracker.follow(
      next.uri,
      "https://example.COM/start",
      301,
      Get,
      @types.HeaderMap::new(),
      ReplayNotRequired,
    )
    is Err(RedirectLoop),
  )
}

///|
test "retry: bounded exponential backoff applies only to allowed failures" {
  let policy = @client.RetryPolicy::idempotent(
    max_attempts=3,
    base_delay_ms=100L,
    max_delay_ms=1000L,
  ).unwrap()
  assert_eq(
    @client.decide_retry(policy, 1, Get, ReplayNotRequired, RetryConnectFailure),
    Ok(RetryAfterMillis(100L)),
  )
  assert_eq(
    @client.decide_retry(
      policy,
      2,
      Get,
      ReplayNotRequired,
      RetryStatus(503),
      jitter_ms=25L,
    ),
    Ok(RetryAfterMillis(225L)),
  )
  assert_eq(
    @client.decide_retry(policy, 3, Get, ReplayNotRequired, RetryConnectFailure),
    Ok(DoNotRetry),
  )
  assert_eq(
    @client.decide_retry(
      policy,
      1,
      Get,
      ReplayNotRequired,
      RetryTlsVerificationFailed,
    ),
    Ok(DoNotRetry),
  )
  assert_eq(
    @client.decide_retry(
      policy,
      1,
      Get,
      ReplayNotRequired,
      RetryBodyPartiallySent,
    ),
    Ok(DoNotRetry),
  )
}

///|
test "retry: method and body gates prevent unsafe automatic replay" {
  let policy = @client.RetryPolicy::idempotent().unwrap()
  assert_eq(
    @client.decide_retry(policy, 1, Post, ReplayableBody, RetryConnectFailure),
    Ok(DoNotRetry),
  )
  assert_true(
    @client.decide_retry(policy, 1, Put, NonReplayableBody, RetryStatus(503))
    is Err(RetryBodyNotReplayable),
  )
  let explicit = @client.RetryPolicy::explicit(
    [Extension("UPLOAD")],
    max_attempts=2,
  ).unwrap()
  assert_eq(
    @client.decide_retry(
      explicit,
      1,
      Extension("UPLOAD"),
      ReplayableBody,
      RetryGoawayUnprocessed,
    ),
    Ok(RetryAfterMillis(100L)),
  )
  assert_true(@client.RetryPolicy::explicit([]) is Err(InvalidRetryPolicy))
}

///|
test "retry: Retry-After accepts delay-seconds and HTTP-date with hard caps" {
  let policy = @client.RetryPolicy::idempotent(
    max_attempts=3,
    base_delay_ms=100L,
    max_delay_ms=5000L,
  ).unwrap()
  assert_eq(
    @client.decide_retry(
      policy,
      1,
      Get,
      ReplayNotRequired,
      RetryStatus(429),
      retry_after=Some("3"),
    ),
    Ok(RetryAfterMillis(3000L)),
  )
  assert_eq(
    @client.decide_retry(
      policy,
      1,
      Get,
      ReplayNotRequired,
      RetryStatus(503),
      retry_after=Some("999999999999999999999999"),
    ),
    Ok(RetryAfterMillis(5000L)),
  )
  assert_eq(
    @client.decide_retry(
      policy,
      1,
      Get,
      ReplayNotRequired,
      RetryStatus(503),
      retry_after=Some("Sun, 06 Nov 1994 08:49:40 GMT"),
      now_seconds=784111777L,
    ),
    Ok(RetryAfterMillis(3000L)),
  )
  assert_eq(
    @client.decide_retry(
      policy,
      1,
      Get,
      ReplayNotRequired,
      RetryStatus(503),
      retry_after=Some("invalid"),
    ),
    Ok(RetryAfterMillis(100L)),
  )
}

///|
async test "client auth: Basic credentials are scoped to the configured origin" {
  let origin = test_uri("http://example.test/")
  let credentials = @auth.BasicCredentials::new("user", "password").unwrap()
  let client = @client.Client::new().unwrap()
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
  let client = @client.Client::new().unwrap()
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
  let client = @client.Client::new().unwrap()
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
  let client = @client.Client::new(content_decoding=true).unwrap()
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
