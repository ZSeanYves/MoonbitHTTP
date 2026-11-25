///|
/// State for one send, shared only by its redirects and retries.
priv struct ClientExchange {
  config : ClientConfig
  now_seconds : Int64
  redirects : RedirectTracker
  mut request : @types.Request[Bytes]
  mut endpoint : ClientEndpoint
  mut auth_attempts : Int32
}

///|
priv enum PreparedRequest {
  LocalResponse(@types.Response[Bytes])
  SendRequest(
    @types.Request[Bytes],
    @auth.DigestAuthorization?,
    @cache.CacheHit?,
  )
}

///|
priv enum ExchangeAction {
  Complete(@types.Response[Bytes])
  SendAgain
  RetryAfter(Int64)
}

///|
async fn[B : ByteRoundTripper] Client::send_inner(
  self : Client,
  executor : B,
  request : @types.Request[Bytes],
  now_seconds : Int64,
) -> Result[@types.Response[Bytes], ClientError] {
  let exchange = ClientExchange::new(self.config, request, now_seconds) catch {
    error => return Err(error)
  }
  // Every call to the executor counts toward the retry budget, including
  // authentication challenges and redirects.
  for attempt = 1 {
    let prepared = exchange.prepare_request() catch {
      error => return Err(error)
    }
    let (outgoing, digest, stale) = match prepared {
      LocalResponse(response) => return Ok(response)
      SendRequest(outgoing, digest, stale) => (outgoing, digest, stale)
    }
    let result = executor.execute(outgoing)
    let action = try {
      match result {
        Ok(response) =>
          exchange.handle_response(outgoing, response, digest, stale, attempt)
        Err(error) => exchange.handle_failure(error, stale, attempt)
      }
    } catch {
      error => return Err(error)
    }
    match action {
      Complete(response) => return Ok(response)
      RetryAfter(delay) => (self.config.wait)(delay)
      SendAgain => ()
    }
    continue attempt + 1
  }
}

///|
fn ClientExchange::new(
  config : ClientConfig,
  request : @types.Request[Bytes],
  now_seconds : Int64,
) -> ClientExchange raise ClientError {
  config.options.validate().unwrap_or_error()
  let endpoint = ClientEndpoint::from_uri(request.uri).unwrap_or_error()
  let redirects = RedirectTracker::new(request.uri, config.options.redirect)
    .map_err(error => ClientRedirect(error))
    .unwrap_or_error()
  {
    config,
    now_seconds,
    redirects,
    endpoint,
    request: { ..request, headers: request.headers.copy(), },
    auth_attempts: 0,
  }
}

///|
fn ClientExchange::prepare_headers(
  self : ClientExchange,
  request : @types.Request[Bytes],
) -> @auth.DigestAuthorization? raise ClientError {
  let headers = request.headers
  if self.endpoint.secure {
    self.config.tls
    .for_server_name(self.endpoint.transport.host())
    .validate_client()
    .map_err(_ => ClientInvalidOptions("invalid TLS options"))
    .unwrap_or_error()
  }
  let context = @cookie.CookieContext::http(request.http_method)
  if self.config.cookie_jar.cookie_header(
      request.uri,
      self.now_seconds,
      context~,
    )
    is Ok(Some(cookie)) &&
    headers.get_string("cookie") is None {
    headers.set(@types.HeaderName::parse("cookie").unwrap(), cookie)
  }
  if self.config.content_decoding &&
    headers.get_string("accept-encoding") is None {
    headers
    .append_string("accept-encoding", "gzip, deflate, br")
    .map_err(_ => ClientInvalidOptions("invalid Accept-Encoding field"))
    .unwrap_or_error()
  }
  let explicit = headers.get_string("authorization") is Some(_)
  self.config.auth
  .apply(
    self.endpoint,
    request.http_method,
    request.uri,
    request.body,
    headers,
    explicit,
  )
  .unwrap_or_error()
}

///|
fn ClientExchange::prepare_request(
  self : ClientExchange,
) -> PreparedRequest raise ClientError {
  // Keep caller fields for retries and redirects. Generated cookies,
  // credentials and cache validators belong to one outbound attempt.
  let request = { ..self.request, headers: self.request.headers.copy(), }
  let digest = self.prepare_headers(request)
  if !self.config.cache_enabled || !(request.http_method is (Get | Head)) {
    return SendRequest(request, digest, None)
  }
  match self.config.cache.lookup(request.map_body(_ => ()), self.now_seconds) {
    Ok(CacheMiss) => SendRequest(request, digest, None)
    Ok(CacheFresh(hit) | CacheStale(hit)) =>
      LocalResponse(self.cached_response(hit))
    Ok(OnlyIfCachedMiss) =>
      LocalResponse({
        status: 504,
        version: request.version,
        headers: @types.HeaderMap::new(),
        body: b"",
      })
    Ok(CacheRevalidate(hit)) =>
      SendRequest(
        {
          ..request,
          headers: @cache.conditional_request_headers(request.headers, hit),
        },
        digest,
        Some(hit),
      )
    Err(_) => raise ClientProtocol("cache lookup failed")
  }
}

///|
fn ClientExchange::retry_decision(
  self : ClientExchange,
  attempt : Int32,
  cause : RetryCause,
  retry_after~ : String? = None,
) -> RetryDecision raise ClientError {
  decide_retry(
    self.config.options.retry,
    attempt,
    self.request.http_method,
    self.config.options.body_replayability,
    cause,
    now_seconds=self.now_seconds,
    retry_after~,
  )
  .map_err(error => ClientRetry(error))
  .unwrap_or_error()
}

///|
fn ClientExchange::handle_failure(
  self : ClientExchange,
  error : ClientError,
  stale : @cache.CacheHit?,
  attempt : Int32,
) -> ExchangeAction raise ClientError {
  if stale is Some(hit) && hit.allows_stale_if_error() {
    return Complete(self.cached_response(hit))
  }
  let cause = match error {
    ClientHttp2(StreamError(_, RefusedStream, _)) => RetryRefusedStream
    ClientTransport(_) => RetryConnectFailure
    ClientTimeout(_, _, _) => RetryTimeoutBeforeResponse
    ClientTls(_) => RetryTlsVerificationFailed
    ClientCancelled(_) => RetryCancelled
    _ => RetryOther
  }
  match self.retry_decision(attempt, cause) {
    DoNotRetry => raise error
    RetryAfterMillis(delay) => RetryAfter(delay)
  }
}

///|
fn ClientExchange::handle_response(
  self : ClientExchange,
  request : @types.Request[Bytes],
  response : @types.Response[Bytes],
  digest : @auth.DigestAuthorization?,
  stale : @cache.CacheHit?,
  attempt : Int32,
) -> ExchangeAction raise ClientError {
  let options = self.config.options
  self.config.auth
  .verify_response(self.endpoint, digest, response)
  .unwrap_or_error()
  if response.status == 401 &&
    self.auth_attempts < 2 &&
    (request.body.is_empty() || options.body_replayability == ReplayableBody) &&
    self.config.auth
    .handle_unauthorized(self.endpoint, response.headers)
    .unwrap_or_error() {
    self.auth_attempts += 1
    return SendAgain
  }

  self.update_cache_and_cookies(response)
  // On a retryable status, exhaust retries before serving a stale response.
  let cause = RetryStatus(response.status)
  if retry_cause_allowed(cause) {
    let retry_after = response.headers
      .get_string("retry-after")
      .map(value => value.to_string_lossy())
    if self.retry_decision(attempt, cause, retry_after~)
      is RetryAfterMillis(delay) {
      return RetryAfter(delay)
    }
  }
  if stale is Some(hit) {
    if response.status >= 500 && hit.allows_stale_if_error() {
      return Complete(self.cached_response(hit))
    }
    if response.status == 304 &&
      self.config.cache.revalidate(
        request.map_body(_ => ()),
        response.map_body(_ => ()),
        self.now_seconds,
      )
      is Ok(refreshed) {
      return Complete(self.cached_response(refreshed))
    }
  }
  if response.status is (301 | 302 | 303 | 307 | 308) {
    guard response.headers.get_string("location") is Some(location) else {
      return Complete(response)
    }
    self.follow_redirect(response.status, location.to_string_lossy())
    return SendAgain
  }

  let decoded = self.decode_response(response)
  if self.config.cache_enabled && request.http_method is (Get | Head) {
    ignore(
      self.config.cache.store(
        request.map_body(_ => ()),
        decoded.map_body(_ => ()),
        decoded.body,
        self.now_seconds,
      ),
    )
  }
  Complete(decoded)
}

///|
fn ClientExchange::update_cache_and_cookies(
  self : ClientExchange,
  response : @types.Response[Bytes],
) -> Unit {
  let request = self.request
  if self.config.cache_enabled && !(request.http_method is (Get | Head)) {
    ignore(
      self.config.cache.invalidate_response(
        request.map_body(_ => ()),
        response.map_body(_ => ()),
      ),
    )
  }
  let context = @cookie.CookieContext::http(request.http_method)
  for cookie in response.headers.get_all_string("set-cookie") {
    ignore(
      self.config.cookie_jar.store(
        cookie,
        request.uri,
        self.now_seconds,
        context~,
      ),
    )
  }
}

///|
fn ClientExchange::follow_redirect(
  self : ClientExchange,
  status : Int32,
  location : String,
) -> Unit raise ClientError {
  let request = self.request
  let decision = self.redirects
    .follow(
      request.uri,
      location,
      status,
      request.http_method,
      request.headers,
      self.config.options.body_replayability,
    )
    .map_err(error => ClientRedirect(error))
    .unwrap_or_error()
  let endpoint = ClientEndpoint::from_uri(decision.uri).unwrap_or_error()
  (self.config.authorize_redirect)(endpoint.transport, Redirect)
  .map_err(error => ClientPolicy(error))
  .unwrap_or_error()
  self.endpoint = endpoint
  self.request = {
    ..request,
    uri: decision.uri,
    http_method: decision.http_method,
    headers: decision.headers,
    body: if decision.drop_body {
      b""
    } else {
      request.body
    },
  }
  self.auth_attempts = 0
}

///|
fn ClientExchange::cached_response(
  self : ClientExchange,
  hit : @cache.CacheHit,
) -> @types.Response[Bytes] raise ClientError {
  let request = self.request
  let response = response_from_cache(hit, request.http_method)
  if response.status == 200 &&
    @cache.evaluate_request_condition(
      request.map_body(_ => ()),
      hit,
      self.now_seconds,
    )
    is Ok(ConditionMatches) {
    let headers = @types.HeaderMap::new()
    for field in response.headers.fields() {
      if field.name.value
        is ("date"
        | "etag"
        | "vary"
        | "content-location"
        | "cache-control"
        | "expires"
        | "age"
        | "last-modified") {
        headers.append(field.name, field.value)
      }
    }
    return { ..response, status: 304, headers, body: b"", }
  }
  self.decode_response(response)
}

///|
fn ClientExchange::decode_response(
  self : ClientExchange,
  response : @types.Response[Bytes],
) -> @types.Response[Bytes] raise ClientError {
  if !self.config.content_decoding ||
    !@types.response_allows_body(self.request.http_method, response.status) {
    return response
  }
  @content_coding.decode_bytes_response(
    response,
    limits=self.config.content_coding_limits,
  )
  .map_err(error => ClientContentCoding(error))
  .unwrap_or_error()
}
