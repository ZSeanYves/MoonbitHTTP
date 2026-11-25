///|
/// State for one send, shared only by its redirects and retries.
priv struct ClientExchange {
  client : Client
  mut now_seconds : Int64
  redirects : RedirectTracker
  mut request : @types.Request[Upload]
  mut endpoint : ClientEndpoint
  mut bypass_revalidation : Bool
  mut auth_attempts : Int32
}

///|
priv enum PreparedRequest {
  LocalResponse(@types.Response[IncomingBody])
  SendRequest(@types.Request[Upload], SignedAttempt?, Bool, @cache.CacheHit?)
}

///|
priv enum ExchangeAction {
  Complete(@types.Response[IncomingBody])
  SendAgain
  RetryAfter(Int64)
}

///|
async fn Client::send_inner(
  self : Client,
  request : @types.Request[Upload],
) -> @types.Response[IncomingBody] {
  let exchange = ClientExchange::new(self, request)
  for attempt = 1 {
    let action = match exchange.prepare_request() {
      LocalResponse(response) => return response
      SendRequest(outgoing, digest, deferred_auth, stale) =>
        exchange.attempt(outgoing, digest, deferred_auth, stale, attempt)
    }
    match action {
      Complete(response) => return response
      RetryAfter(delay) => (self.wait)(delay)
      SendAgain => ()
    }
    exchange.now_seconds = (self.wall_clock_seconds)()
    continue attempt + 1
  }
}

///|
/// Owns one network attempt. All its resources are released before the caller waits or retries.
async fn ClientExchange::attempt(
  self : ClientExchange,
  outgoing : @types.Request[Upload],
  digest : SignedAttempt?,
  deferred_auth : Bool,
  stale : @cache.CacheHit?,
  attempt : Int32,
) -> ExchangeAction {
  let source = outgoing.body.open()
  let mut handed_off = false
  defer (if !handed_off { source.cancel(@body.BodyError::Cancelled) })
  let (upload, authorization) = if deferred_auth {
    match outgoing.body.source {
      Reopen(_) => {
        let (data, trailers) = @body.collect(
          source,
          max_bytes=self.client.options.limits.max_body_bytes,
        ) catch {
          @body.BodyLimitExceeded(limit~) => raise ClientBodyLimit(limit)
          error => raise error
        }
        (saved_body(data, trailers), self.apply_auth(outgoing, Some(data)))
      }
      _ => (source, self.apply_auth(outgoing, None))
    }
  } else {
    (source, digest)
  }
  let fill = if self.client.cache_enabled {
    self.client.cache.begin_fill(outgoing.map_body(_ => ()))
  } else {
    None
  }
  defer (if !handed_off && fill is Some(pending) { pending.discard() })
  let result = Ok((self.client.exchange)(outgoing.map_body(_ => upload))) catch {
    error => Err(error)
  }
  match result {
    Err(error) => self.handle_failure(error, stale, attempt)
    Ok(raw) => {
      defer (if !handed_off { raw.body.cancel(@body.BodyError::Cancelled) })
      self.now_seconds = (self.client.wall_clock_seconds)()
      let response = self.authenticated_response(raw, authorization)
      match self.handle_response(outgoing, response, stale, attempt) {
        None => {
          let result = self.deliver(response, fill, upload)
          handed_off = true
          Complete(result)
        }
        Some(action) => action
      }
    }
  }
}

///|
fn ClientExchange::new(
  client : Client,
  request : @types.Request[Upload],
) -> ClientExchange raise ClientError {
  let endpoint = ClientEndpoint::from_uri(request.uri).unwrap_or_error()
  let redirects = RedirectTracker::from_endpoint(
      request.uri,
      Ok(endpoint),
      client.options.redirect,
    )
    .map_err(error => ClientRedirect(error))
    .unwrap_or_error()
  {
    client,
    now_seconds: (client.wall_clock_seconds)(),
    redirects,
    endpoint,
    request: { ..request, headers: request.headers.copy(), },
    auth_attempts: 0,
    bypass_revalidation: false,
  }
}

///|
fn ClientExchange::prepare_headers(
  self : ClientExchange,
  request : @types.Request[Upload],
) -> Unit raise ClientError {
  let headers = request.headers
  if self.endpoint.secure {
    self.client.tls
    .for_server_name(self.endpoint.transport.host())
    .validate_client()
    .map_err(_ => ClientInvalidOptions("invalid TLS options"))
    .unwrap_or_error()
  }
  let context = @cookie.CookieContext::http(request.http_method)
  if self.client.cookie_jar.cookie_header(
      request.uri,
      self.now_seconds,
      context~,
    )
    is Ok(Some(cookie)) &&
    headers.get_string("cookie") is None {
    headers.set(@types.HeaderName::parse("cookie").unwrap(), cookie)
  }
  if self.client.content_decoding &&
    headers.get_string("range") is None &&
    headers.get_string("accept-encoding") is None {
    headers
    .append_string("accept-encoding", "gzip, deflate, br")
    .map_err(_ => ClientInvalidOptions("invalid Accept-Encoding field"))
    .unwrap_or_error()
  }
}

///|
fn ClientExchange::apply_auth(
  self : ClientExchange,
  request : @types.Request[Upload],
  data : Bytes?,
) -> SignedAttempt? raise ClientError {
  let headers = request.headers
  let explicit = headers.get_string("authorization") is Some(_)
  self.client.auth
  .apply(
    self.endpoint,
    request.http_method,
    request.uri,
    data,
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
  self.prepare_headers(request)
  let deferred_auth = request.headers.get_string("authorization") is None &&
    self.client.auth.wants_entity(self.endpoint) &&
    !(request.body.source is Buffered(_))
  let digest = if deferred_auth {
    None
  } else {
    self.apply_auth(
      request,
      match request.body.source {
        Buffered(data) => Some(data)
        _ => None
      },
    )
  }
  if self.bypass_revalidation ||
    !self.client.cache_enabled ||
    !(request.http_method is (Get | Head)) {
    return SendRequest(request, digest, deferred_auth, None)
  }
  match
    self.client.cache.lookup(
      request.map_body(_ => ()),
      self.now_seconds,
      unknown_authorization=deferred_auth,
    ) {
    Ok(CacheMiss) => SendRequest(request, digest, deferred_auth, None)
    Ok(CacheFresh(hit) | CacheStale(hit)) =>
      LocalResponse(self.cached_response(hit))
    Ok(OnlyIfCachedMiss) =>
      LocalResponse({
        status: 504,
        version: request.version,
        headers: @types.HeaderMap::new(),
        body: saved_body(b"", None),
      })
    Ok(CacheRevalidate(hit)) =>
      SendRequest(
        {
          ..request,
          headers: @cache.conditional_request_headers(request.headers, hit),
        },
        digest,
        deferred_auth,
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
    self.client.options.retry,
    attempt,
    self.request.http_method,
    self.request.body.replayability(),
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
  error : Error,
  stale : @cache.CacheHit?,
  attempt : Int32,
) -> ExchangeAction raise {
  let cause = match error {
    ClientError::ClientHttp3(Goaway(_)) | ClientError::ClientH3Rejected(_) =>
      RetryGoawayUnprocessed
    ClientError::ClientHttp2(StreamError(_, RefusedStream, _)) =>
      RetryRefusedStream
    ClientError::ClientTransport(Policy(_)) => RetryPolicyDenied
    ClientError::ClientTransport(Cancelled) => RetryCancelled
    ClientError::ClientTransport(_) => RetryConnectFailure
    ClientError::ClientTimeout(_, _, _) => RetryTimeoutBeforeResponse
    ClientError::ClientTls(_) => RetryTlsVerificationFailed
    ClientError::ClientCancelled(_) => RetryCancelled
    _ => RetryOther
  }
  if cause is (RetryConnectFailure | RetryTimeoutBeforeResponse) &&
    stale is Some(hit) &&
    hit.allows_stale_if_error() {
    return Complete(self.cached_response(hit))
  }
  match self.retry_decision(attempt, cause) {
    DoNotRetry => raise error
    RetryAfterMillis(delay) => RetryAfter(delay)
  }
}

///|
fn ClientExchange::handle_response(
  self : ClientExchange,
  request : @types.Request[Upload],
  response : @types.Response[IncomingBody],
  stale : @cache.CacheHit?,
  attempt : Int32,
) -> ExchangeAction? raise ClientError {
  self.store_cookies(response.headers)
  if response.status == 401 &&
    self.auth_attempts < 2 &&
    request.body.replayability() == ReplayableBody &&
    self.client.auth
    .handle_unauthorized(self.endpoint, response.headers)
    .unwrap_or_error() {
    self.auth_attempts += 1
    return Some(SendAgain)
  }

  if self.client.cache_enabled && !(request.http_method is (Get | Head)) {
    ignore(
      self.client.cache.invalidate_response(
        request.map_body(_ => ()),
        response.map_body(_ => ()),
      ),
    )
  }
  // On a retryable status, exhaust retries before serving a stale response.
  let cause = RetryStatus(response.status)
  if retry_cause_allowed(cause) {
    let retry_after = response.headers
      .get_string("retry-after")
      .map(value => value.to_string_lossy())
    if self.retry_decision(attempt, cause, retry_after~)
      is RetryAfterMillis(delay) {
      return Some(RetryAfter(delay))
    }
  }
  if stale is Some(hit) {
    if response.status >= 500 && hit.allows_stale_if_error() {
      return Some(Complete(self.cached_response(hit)))
    }
    if response.status == 304 &&
      self.client.cache.revalidate(
        request.map_body(_ => ()),
        response.map_body(_ => ()),
        self.now_seconds,
      )
      is Ok(refreshed) {
      return Some(Complete(self.cached_response(refreshed)))
    }
  }
  if response.status == 304 {
    // Only a validator actually sent by the caller can justify forwarding a 304.
    let caller = self.request.headers
    let supplied = caller.get_string("if-none-match") is Some(_) ||
      (
        caller.get_string("if-modified-since") is Some(_) &&
        request.headers.get_string("if-none-match") is None
      )
    if !supplied && (stale is Some(_) || self.bypass_revalidation) {
      if self.bypass_revalidation ||
        request.body.replayability() == NonReplayableBody {
        raise ClientProtocol("304 has no usable cached representation")
      }
      self.bypass_revalidation = true
      return Some(SendAgain)
    }
  }
  if response.status is (301 | 302 | 303 | 307 | 308) {
    guard response.headers.get_string("location") is Some(location) else {
      return None
    }
    self.follow_redirect(response.status, location.to_string_lossy())
    return Some(SendAgain)
  }

  None
}

///|
fn ClientExchange::store_cookies(
  self : ClientExchange,
  headers : @types.HeaderMap,
) -> Unit {
  let request = self.request
  let context = @cookie.CookieContext::http(request.http_method)
  for cookie in headers.get_all_string("set-cookie") {
    ignore(
      self.client.cookie_jar.store(
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
  let (decision, endpoint) = self.redirects
    .resolve(
      request.uri,
      Ok(self.endpoint),
      location,
      status,
      request.http_method,
      request.headers,
      self.request.body.replayability(),
    )
    .map_err(error => ClientRedirect(error))
    .unwrap_or_error()
  (self.client.authorize_redirect)(endpoint.transport, Redirect)
  .map_err(error => ClientPolicy(error))
  .unwrap_or_error()
  self.endpoint = endpoint
  self.request = {
    ..request,
    uri: decision.uri,
    http_method: decision.http_method,
    headers: decision.headers,
    body: if decision.drop_body {
      Upload::bytes(b"")
    } else {
      request.body
    },
  }
  self.bypass_revalidation = false
  self.auth_attempts = 0
}

///|
fn ClientExchange::cached_response(
  self : ClientExchange,
  hit : @cache.CacheHit,
) -> @types.Response[IncomingBody] raise ClientError {
  let request = self.request
  let response = response_from_cache(hit, request.http_method).map_body(data => {
    saved_body(data, hit.trailers)
  })
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
    return { ..response, status: 304, headers, body: saved_body(b"", None), }
  }
  self.decode_response(response)
}

///|
fn ClientExchange::decode_response(
  self : ClientExchange,
  response : @types.Response[IncomingBody],
) -> @types.Response[IncomingBody] raise ClientError {
  if !self.client.content_decoding ||
    response.status == 206 ||
    !@types.response_allows_body(self.request.http_method, response.status) {
    return response
  }
  @content_coding.decode_response(
    response,
    limits=self.client.content_coding_limits,
  )
  .map_err(error => ClientContentCoding(error))
  .unwrap_or_error()
  .map_body(body => IncomingBody::wrap(body))
}
