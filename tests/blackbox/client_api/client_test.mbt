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
}

///|
async test "client: default TLS options are constructible before an endpoint is known" {
  @client.with_client(
    client => {
      assert_true(client.tls().verify_peer)
      assert_true(client.tls().server_name is None)
    },
    version=Http11,
    exchange=_ => fail("unexpected request"),
    now_millis=() => 0L,
    wall_clock_seconds=() => 0L,
    authorize_redirect=(_, _) => Ok(()),
  )
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
test "redirect: a POST can become a GET on the same URI only once" {
  let uri = test_uri("https://example.com/form")
  let tracker = @client.RedirectTracker::new(
    uri,
    @client.RedirectPolicy::limited().unwrap(),
  ).unwrap()
  let headers = @types.HeaderMap::new()
  let next = tracker
    .follow(uri, "/form", 303, Post, headers, NonReplayableBody)
    .unwrap_or_error()
  assert_eq(next.http_method, Get)
  assert_true(next.drop_body)
  assert_true(
    tracker.follow(next.uri, "/form", 303, Get, headers, ReplayableBody)
    is Err(RedirectLoop),
  )

  let same = @client.RedirectTracker::new(
    uri,
    @client.RedirectPolicy::limited().unwrap(),
  ).unwrap()
  assert_true(
    same.follow(uri, "/form", 307, Post, headers, ReplayableBody)
    is Err(RedirectLoop),
  )
}
