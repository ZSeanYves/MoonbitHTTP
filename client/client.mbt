///|
pub(all) struct ClientConfig {
  options : RequestOptions
  proxy : ProxyConfig
  tls : @tls.TlsOptions
  cookie_jar : @cookie.CookieJar
  cache : @cache.HttpCache
  mut cache_enabled : Bool
  wait : async (Int64) -> Unit
  authorize_redirect : (@transport.Endpoint, @transport.PolicyOperation) -> Result[
    Unit,
    @transport.PolicyError,
  ]
  now_millis : () -> Int64
  priv auth : ClientAuthStore
  priv mut content_decoding : Bool
  priv content_coding_limits : @content_coding.ContentCodingLimits
}

///|
pub struct Client {
  config : ClientConfig
}

///|
async fn client_default_wait(delay_ms : Int64) -> Unit {
  let bounded = delay_ms.max(0L).min(2147483647L)
  if bounded > 0L {
    @async.sleep(bounded.to_int())
  }
}

///|
pub fn Client::new(
  options? : RequestOptions = RequestOptions::defaults(),
  proxy? : ProxyConfig = ProxyConfig::direct(),
  tls? : @tls.TlsOptions = @tls.TlsOptions::defaults(),
  cookie_jar? : @cookie.CookieJar = @cookie.CookieJar::new().unwrap(),
  cache? : @cache.HttpCache = @cache.HttpCache::new().unwrap(),
  cache_enabled? : Bool = false,
  wait? : async (Int64) -> Unit = client_default_wait,
  authorize_redirect? : (@transport.Endpoint, @transport.PolicyOperation) -> Result[
    Unit,
    @transport.PolicyError,
  ] = fn(_, _) { Ok(()) },
  now_millis? : () -> Int64 = fn() { 0L },
  content_decoding? : Bool = false,
  content_coding_limits? : @content_coding.ContentCodingLimits = @content_coding.ContentCodingLimits::defaults(),
) -> Result[Client, ClientError] {
  match options.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match proxy.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  // The endpoint supplies SNI/hostname identity when the caller leaves
  // `server_name` unset.  Validate syntax and certificate pairing here, then
  // perform the endpoint-specific hostname check in `send`.
  match tls.validate_common() {
    Ok(_) => ()
    Err(_) => return Err(ClientInvalidOptions("invalid TLS options"))
  }
  match content_coding_limits.validate() {
    Ok(_) => ()
    Err(_) => return Err(ClientInvalidOptions("invalid content coding limits"))
  }
  Ok({
    config: {
      options,
      proxy,
      tls,
      cookie_jar,
      cache,
      cache_enabled,
      wait,
      authorize_redirect,
      now_millis,
      auth: ClientAuthStore::new(),
      content_decoding,
      content_coding_limits,
    },
  })
}

///|
pub fn Client::options(self : Client) -> RequestOptions {
  self.config.options
}

///|
pub fn Client::proxy(self : Client) -> ProxyConfig {
  self.config.proxy
}

///|
pub fn Client::tls(self : Client) -> @tls.TlsOptions {
  self.config.tls
}

///|
pub fn Client::set_cache_enabled(self : Client, enabled : Bool) -> Unit {
  self.config.cache_enabled = enabled
}

///|
/// Enables or disables automatic response content decoding. When enabled, the
/// client advertises the supported codings unless the caller supplied an
/// `Accept-Encoding` field.
pub fn Client::set_content_decoding(self : Client, enabled : Bool) -> Unit {
  self.config.content_decoding = enabled
}

///|
pub fn Client::content_decoding(self : Client) -> Bool {
  self.config.content_decoding
}

///|
pub fn Client::content_coding_limits(
  self : Client,
) -> @content_coding.ContentCodingLimits {
  self.config.content_coding_limits
}

///|
pub fn Client::cookie_jar(self : Client) -> @cookie.CookieJar {
  self.config.cookie_jar
}

///|
pub fn Client::cache(self : Client) -> @cache.HttpCache {
  self.config.cache
}

///|
fn client_request_copy(
  request : @types.Request[Bytes],
  request_method : @types.Method,
  uri : @types.Uri,
  headers : @types.HeaderMap,
  body : Bytes,
) -> @types.Request[Bytes] {
  { http_method: request_method, uri, version: request.version, headers, body, }
}

///|
fn client_response_copy(
  response : @types.Response[Bytes],
) -> @types.Response[Unit] {
  {
    status: response.status,
    version: response.version,
    headers: response.headers,
    body: (),
  }
}

///|
fn client_retry_cause(error : ClientError) -> RetryCause {
  match error {
    ClientTransport(_) => RetryConnectFailure
    ClientTimeout(_, _, _) => RetryTimeoutBeforeResponse
    ClientTls(_) => RetryTlsVerificationFailed
    ClientCancelled(_) => RetryCancelled
    _ => RetryOther
  }
}

///|
fn client_location(response : @types.Response[Bytes]) -> String? {
  match response.headers.get_string("location") {
    Some(value) => Some(value.to_string_lossy())
    None => None
  }
}

///|
fn client_remove_authorization(headers : @types.HeaderMap) -> Unit {
  match @types.HeaderName::parse("authorization") {
    Ok(name) => headers.remove(name)
    Err(_) => ()
  }
}

///|
fn Client::prepare_content_decoding(
  self : Client,
  headers : @types.HeaderMap,
) -> Result[Unit, ClientError] {
  if !self.config.content_decoding ||
    headers.get_string("accept-encoding") is Some(_) {
    return Ok(())
  }
  match headers.append_string("accept-encoding", "gzip, deflate, br") {
    Ok(_) => Ok(())
    Err(_) => Err(ClientInvalidOptions("invalid Accept-Encoding field"))
  }
}

///|
fn Client::decode_response_bytes(
  self : Client,
  response : @types.Response[Bytes],
) -> Result[@types.Response[Bytes], ClientError] {
  if !self.config.content_decoding {
    return Ok(response)
  }
  match
    @content_coding.decode_bytes_response(
      response,
      limits=self.config.content_coding_limits,
    ) {
    Ok(value) => Ok(value)
    Err(error) => Err(ClientContentCoding(error))
  }
}

///|
fn client_auth_body_replayable(
  body : Bytes,
  replayability : BodyReplayability,
) -> Bool {
  body.is_empty() || replayability == ReplayableBody
}

///|
async fn[B : ByteRoundTripper] Client::send_inner(
  self : Client,
  executor : B,
  request : @types.Request[Bytes],
  now_seconds : Int64,
) -> Result[@types.Response[Bytes], ClientError] {
  match self.config.options.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match ClientEndpoint::from_uri(request.uri) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let tracker = match
    RedirectTracker::new(request.uri, self.config.options.redirect) {
    Ok(value) => value
    Err(error) => return Err(ClientRedirect(error))
  }
  let mut current_method = request.http_method
  let mut current_uri = request.uri
  let mut current_headers = request.headers.copy()
  let original_body = request.body
  let mut current_body = original_body
  let mut attempts = 0
  let mut auth_attempts = 0
  let mut managed_authorization = false
  let tracker = tracker
  while true {
    let endpoint = match ClientEndpoint::from_uri(current_uri) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if endpoint.secure {
      let tls_options = self.config.tls.for_server_name(
        endpoint.transport.host(),
      )
      match tls_options.validate_client() {
        Ok(_) => ()
        Err(_) => return Err(ClientInvalidOptions("invalid TLS options"))
      }
    }
    let context = @cookie.CookieContext::http(current_method)
    match
      self.config.cookie_jar.cookie_header(current_uri, now_seconds, context~) {
      Ok(Some(cookie)) =>
        if current_headers.get_string("cookie") is None {
          match @types.HeaderName::parse("cookie") {
            Ok(name) => current_headers.set(name, cookie)
            Err(_) => ()
          }
        }
      Ok(None) => ()
      Err(_) => ()
    }
    if managed_authorization {
      client_remove_authorization(current_headers)
      managed_authorization = false
    }
    match self.prepare_content_decoding(current_headers) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    let explicit_authorization = current_headers.get_string("authorization")
      is Some(_)
    let digest_authorization = match
      self.config.auth.apply(
        endpoint, current_method, current_uri, current_body, current_headers, explicit_authorization,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    managed_authorization = !explicit_authorization &&
      current_headers.get_string("authorization") is Some(_)
    let mut cache_hit : @cache.CacheHit? = None
    if self.config.cache_enabled &&
      (current_method == Get || current_method == Head) {
      let cache_request : @types.Request[Unit] = {
        http_method: current_method,
        uri: current_uri,
        version: request.version,
        headers: current_headers,
        body: (),
      }
      match self.config.cache.lookup(cache_request, now_seconds) {
        Ok(CacheFresh(hit) | CacheStale(hit)) => {
          let cached = response_from_cache(hit, current_method)
          return self.decode_response_bytes(cached)
        }
        Ok(CacheRevalidate(hit)) => {
          cache_hit = Some(hit)
          current_headers = @cache.conditional_request_headers(
            current_headers, hit,
          )
        }
        Ok(_) => ()
        Err(_) => return Err(ClientProtocol("cache lookup failed"))
      }
    }
    let outgoing = client_request_copy(
      request, current_method, current_uri, current_headers, current_body,
    )
    let result = executor.execute(outgoing)
    attempts += 1
    match result {
      Err(error) => {
        match cache_hit {
          Some(hit) if hit.stale_seconds() <= hit.stale_if_error() => {
            let cached = response_from_cache(hit, current_method)
            return self.decode_response_bytes(cached)
          }
          _ => ()
        }
        let replayability = if self.config.options.body_replayability ==
          NonReplayableBody {
          NonReplayableBody
        } else {
          ReplayableBody
        }
        let decision = match
          decide_retry(
            self.config.options.retry,
            attempts,
            current_method,
            replayability,
            client_retry_cause(error),
            now_seconds~,
          ) {
          Ok(value) => value
          Err(retry_error) => return Err(ClientRetry(retry_error))
        }
        match decision {
          DoNotRetry => return Err(error)
          RetryAfterMillis(delay) => {
            (self.config.wait)(delay)
            continue
          }
        }
      }
      Ok(response) => {
        match
          self.config.auth.verify_response(
            endpoint, digest_authorization, response,
          ) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
        if response.status == 401 &&
          auth_attempts < 2 &&
          client_auth_body_replayable(
            current_body,
            self.config.options.body_replayability,
          ) {
          let challenged = match
            self.config.auth.handle_unauthorized(endpoint, response.headers) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          if challenged {
            auth_attempts += 1
            continue
          }
        }
        if self.config.cache_enabled &&
          current_method != Get &&
          current_method != Head {
          let invalidation_request : @types.Request[Unit] = {
            http_method: current_method,
            uri: current_uri,
            version: request.version,
            headers: current_headers,
            body: (),
          }
          ignore(
            self.config.cache.invalidate_response(
              invalidation_request,
              client_response_copy(response),
            ),
          )
        }
        for cookie in response.headers.get_all_string("set-cookie") {
          ignore(
            self.config.cookie_jar.store(
              cookie,
              current_uri,
              now_seconds,
              context~,
            ),
          )
        }
        if response.status == 408 ||
          response.status == 425 ||
          response.status == 429 ||
          response.status == 500 ||
          response.status == 502 ||
          response.status == 503 ||
          response.status == 504 {
          let retry_after = match response.headers.get_string("retry-after") {
            Some(value) => Some(value.to_string_lossy())
            None => None
          }
          let replayability = if self.config.options.body_replayability ==
            NonReplayableBody {
            NonReplayableBody
          } else {
            ReplayableBody
          }
          let decision = match
            decide_retry(
              self.config.options.retry,
              attempts,
              current_method,
              replayability,
              RetryStatus(response.status),
              retry_after~,
              now_seconds~,
            ) {
            Ok(value) => value
            Err(retry_error) => return Err(ClientRetry(retry_error))
          }
          match decision {
            RetryAfterMillis(delay) => {
              (self.config.wait)(delay)
              continue
            }
            DoNotRetry => ()
          }
        }
        if cache_hit is Some(hit) &&
          response.status >= 500 &&
          hit.stale_seconds() <= hit.stale_if_error() {
          let cached = response_from_cache(hit, current_method)
          return self.decode_response_bytes(cached)
        }
        if response.status == 304 && cache_hit is Some(_) {
          let stored_request : @types.Request[Unit] = {
            http_method: current_method,
            uri: current_uri,
            version: request.version,
            headers: current_headers,
            body: (),
          }
          let not_modified = client_response_copy(response)
          match
            self.config.cache.revalidate(
              stored_request, not_modified, now_seconds,
            ) {
            Ok(refreshed) => {
              let cached = response_from_cache(refreshed, current_method)
              return self.decode_response_bytes(cached)
            }
            Err(_) => ()
          }
        }
        if response.status == 301 ||
          response.status == 302 ||
          response.status == 303 ||
          response.status == 307 ||
          response.status == 308 {
          let location = match client_location(response) {
            Some(value) => value
            None => return Ok(response)
          }
          let decision = match
            tracker.follow(
              current_uri,
              location,
              response.status,
              current_method,
              current_headers,
              if self.config.options.body_replayability == NonReplayableBody {
                NonReplayableBody
              } else {
                ReplayableBody
              },
            ) {
            Ok(value) => value
            Err(error) => return Err(ClientRedirect(error))
          }
          let redirect_endpoint = match ClientEndpoint::from_uri(decision.uri) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          match
            (self.config.authorize_redirect)(
              redirect_endpoint.transport,
              Redirect,
            ) {
            Ok(_) => ()
            Err(error) => return Err(ClientPolicy(error))
          }
          current_uri = decision.uri
          current_method = decision.http_method
          current_headers = decision.headers
          if decision.cross_origin {
            managed_authorization = false
          }
          auth_attempts = 0
          if decision.drop_body {
            current_body = b""
          }
          continue
        }
        let response = match self.decode_response_bytes(response) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        if self.config.cache_enabled &&
          (current_method == Get || current_method == Head) {
          let cache_request : @types.Request[Unit] = {
            http_method: current_method,
            uri: current_uri,
            version: request.version,
            headers: current_headers,
            body: (),
          }
          ignore(
            self.config.cache.store(
              cache_request,
              client_response_copy(response),
              response.body,
              now_seconds,
            ),
          )
        }
        return Ok(response)
      }
    }
  } nobreak {
    Err(ClientProtocol("client policy loop terminated"))
  }
}

///|
fn client_total_deadline(start : Int64, timeout_ms : Int) -> Int64 {
  let timeout = timeout_ms.to_int64()
  if start > @int64.MAX_VALUE - timeout {
    @int64.MAX_VALUE
  } else {
    start + timeout
  }
}

///|
pub async fn[B : ByteRoundTripper] Client::send(
  self : Client,
  executor : B,
  request : @types.Request[Bytes],
  now_seconds : Int64,
) -> Result[@types.Response[Bytes], ClientError] {
  match self.config.options.timeouts.total_ms {
    None => self.send_inner(executor, request, now_seconds)
    Some(timeout) => {
      let started = (self.config.now_millis)().max(0L)
      @async.with_timeout(timeout, async fn() {
        self.send_inner(executor, request, now_seconds)
      }) catch {
        @async.TimeoutError => {
          let elapsed = ((self.config.now_millis)().max(started) - started).max(
            timeout.to_int64(),
          )
          Err(
            ClientTimeout(
              ClientTotal,
              elapsed,
              client_total_deadline(started, timeout),
            ),
          )
        }
        error => raise error
      }
    }
  }
}
