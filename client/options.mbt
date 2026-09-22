///|
pub(all) struct ClientEndpoint {
  uri : @types.Uri
  transport : @transport.Endpoint
  secure : Bool
  origin : String
} derive(Eq, Debug)

///|
fn client_render_host(host : String) -> String {
  if host.contains(":") && !host.has_prefix("[") {
    "[" + host + "]"
  } else {
    host
  }
}

///|
fn client_ascii_lower(value : String) -> String {
  let bytes = @utf8.encode(value)
  let lowered = FixedArray::make(bytes.length(), b'0')
  for index in 0..<bytes.length() {
    let byte = bytes[index]
    lowered[index] = if byte >= b'A' && byte <= b'Z' {
      (byte.to_int() + 32).to_byte()
    } else {
      byte
    }
  }
  @utf8.decode(lowered.unsafe_reinterpret_as_bytes()) catch {
    _ => value
  }
}

///|
pub fn ClientEndpoint::from_uri(
  uri : @types.Uri,
) -> Result[ClientEndpoint, ClientError] {
  match uri.validate() {
    Ok(_) => ()
    Err(error) => return Err(ClientInvalidUri(error))
  }
  if uri.form != AbsoluteForm || uri.fragment is Some(_) {
    return Err(
      ClientInvalidOptions("client URI must be absolute and fragment-free"),
    )
  }
  let scheme = match uri.scheme {
    Some("http") => "http"
    Some("https") => "https"
    _ =>
      return Err(
        ClientInvalidOptions("client URI scheme must be http or https"),
      )
  }
  let authority = match uri.authority {
    Some(value) if value.userinfo is None => value
    Some(_) =>
      return Err(ClientInvalidOptions("client URI must not contain userinfo"))
    None => return Err(ClientInvalidOptions("client URI authority is missing"))
  }
  let port = match authority.port {
    Some(value) => value
    None => if scheme == "https" { 443 } else { 80 }
  }
  let normalized_host = client_ascii_lower(authority.host)
  let transport = match
    @transport.Endpoint::new(scheme, normalized_host, port) {
    Ok(value) => value
    Err(error) => return Err(ClientInvalidEndpoint(error))
  }
  let origin = scheme +
    "://" +
    client_render_host(normalized_host) +
    ":" +
    port.to_string()
  Ok({ uri, transport, secure: scheme == "https", origin, })
}

///|
pub fn ClientEndpoint::same_origin(
  self : ClientEndpoint,
  other : ClientEndpoint,
) -> Bool {
  self.origin == other.origin
}

///|
pub(all) struct ClientTimeouts {
  resolve_ms : Int?
  connect_ms : Int?
  tls_ms : Int?
  request_headers_ms : Int?
  request_body_ms : Int?
  response_headers_ms : Int?
  response_body_ms : Int?
  idle_ms : Int?
  total_ms : Int?
} derive(Eq, Debug)

///|
pub fn ClientTimeouts::defaults() -> ClientTimeouts {
  {
    resolve_ms: Some(10000),
    connect_ms: Some(10000),
    tls_ms: Some(10000),
    request_headers_ms: Some(30000),
    request_body_ms: Some(30000),
    response_headers_ms: Some(30000),
    response_body_ms: Some(60000),
    idle_ms: Some(60000),
    total_ms: Some(120000),
  }
}

///|
pub fn ClientTimeouts::validate(
  self : ClientTimeouts,
) -> Result[Unit, ClientError] {
  let values : Array[(String, Int?)] = [
    ("resolve", self.resolve_ms),
    ("connect", self.connect_ms),
    ("TLS", self.tls_ms),
    ("request headers", self.request_headers_ms),
    ("request body", self.request_body_ms),
    ("response headers", self.response_headers_ms),
    ("response body", self.response_body_ms),
    ("idle", self.idle_ms),
    ("total", self.total_ms),
  ]
  for entry in values {
    let (name, value) = entry
    if value is Some(timeout) && timeout <= 0 {
      return Err(ClientInvalidOptions(name + " timeout must be positive"))
    }
  }
  Ok(())
}

///|
pub(all) struct RedirectPolicy {
  enabled : Bool
  max_redirects : Int
  allow_https_downgrade : Bool
} derive(Eq, Debug)

///|
pub fn RedirectPolicy::disabled() -> RedirectPolicy {
  { enabled: false, max_redirects: 0, allow_https_downgrade: false, }
}

///|
pub fn RedirectPolicy::limited(
  max_redirects? : Int = 10,
  allow_https_downgrade? : Bool = false,
) -> Result[RedirectPolicy, RedirectError] {
  if max_redirects < 1 {
    Err(RedirectLimitExceeded(max_redirects))
  } else {
    Ok({ enabled: true, max_redirects, allow_https_downgrade, })
  }
}

///|
pub(all) enum RetryMode {
  RetryDisabled
  RetryIdempotent
  RetryExplicit(Array[@types.Method])
} derive(Eq, Debug)

///|
pub(all) struct RetryPolicy {
  mode : RetryMode
  max_attempts : Int
  base_delay_ms : Int64
  max_delay_ms : Int64
  respect_retry_after : Bool
} derive(Eq, Debug)

///|
pub fn RetryPolicy::disabled() -> RetryPolicy {
  {
    mode: RetryDisabled,
    max_attempts: 1,
    base_delay_ms: 0L,
    max_delay_ms: 0L,
    respect_retry_after: false,
  }
}

///|
pub fn RetryPolicy::idempotent(
  max_attempts? : Int = 3,
  base_delay_ms? : Int64 = 100L,
  max_delay_ms? : Int64 = 30000L,
  respect_retry_after? : Bool = true,
) -> Result[RetryPolicy, RetryError] {
  let policy = {
    mode: RetryIdempotent,
    max_attempts,
    base_delay_ms,
    max_delay_ms,
    respect_retry_after,
  }
  match policy.validate() {
    Ok(_) => Ok(policy)
    Err(error) => Err(error)
  }
}

///|
pub fn RetryPolicy::explicit(
  methods : Array[@types.Method],
  max_attempts? : Int = 3,
  base_delay_ms? : Int64 = 100L,
  max_delay_ms? : Int64 = 30000L,
  respect_retry_after? : Bool = true,
) -> Result[RetryPolicy, RetryError] {
  if methods.is_empty() {
    return Err(InvalidRetryPolicy)
  }
  let policy = {
    mode: RetryExplicit(methods.copy()),
    max_attempts,
    base_delay_ms,
    max_delay_ms,
    respect_retry_after,
  }
  match policy.validate() {
    Ok(_) => Ok(policy)
    Err(error) => Err(error)
  }
}

///|
pub fn RetryPolicy::validate(self : RetryPolicy) -> Result[Unit, RetryError] {
  if self.max_attempts < 1 ||
    self.base_delay_ms < 0L ||
    self.max_delay_ms < self.base_delay_ms {
    Err(InvalidRetryPolicy)
  } else if self.mode == RetryDisabled && self.max_attempts != 1 {
    Err(InvalidRetryPolicy)
  } else if self.mode is RetryExplicit(methods) && methods.is_empty() {
    Err(InvalidRetryPolicy)
  } else {
    Ok(())
  }
}

///|
pub(all) enum BodyReplayability {
  ReplayNotRequired
  ReplayableBody
  NonReplayableBody
} derive(Eq, Debug)

///|
pub(all) struct RequestOptions {
  limits : @types.Limits
  timeouts : ClientTimeouts
  redirect : RedirectPolicy
  retry : RetryPolicy
  body_replayability : BodyReplayability
  explicitly_idempotent : Bool
  allow_early_data : Bool
} derive(Eq, Debug)

///|
pub fn RequestOptions::defaults() -> RequestOptions {
  {
    limits: @types.Limits::defaults(),
    timeouts: ClientTimeouts::defaults(),
    redirect: RedirectPolicy::disabled(),
    retry: RetryPolicy::disabled(),
    body_replayability: ReplayNotRequired,
    explicitly_idempotent: false,
    allow_early_data: false,
  }
}

///|
pub fn RequestOptions::validate(
  self : RequestOptions,
) -> Result[Unit, ClientError] {
  match self.limits.validate() {
    Ok(_) => ()
    Err(_) => return Err(ClientInvalidOptions("invalid shared resource limits"))
  }
  match self.timeouts.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match self.retry.validate() {
    Ok(_) => ()
    Err(error) => return Err(ClientRetry(error))
  }
  if self.redirect.enabled && self.redirect.max_redirects < 1 {
    return Err(
      ClientRedirect(RedirectLimitExceeded(self.redirect.max_redirects)),
    )
  }
  if self.allow_early_data &&
    (
      self.body_replayability == NonReplayableBody ||
      !self.explicitly_idempotent
    ) {
    return Err(
      ClientInvalidOptions(
        "early data requires replayable, explicitly idempotent requests",
      ),
    )
  }
  Ok(())
}

///|
pub(all) enum ProxyMode {
  Direct
  HttpForward
  HttpsConnect
} derive(Eq, Debug)

///|
pub(all) struct ProxyConfig {
  mode : ProxyMode
  endpoint : @transport.Endpoint?
  identity_key : String?
} derive(Eq, Debug)

///|
pub fn ProxyConfig::direct() -> ProxyConfig {
  { mode: Direct, endpoint: None, identity_key: None, }
}

///|
pub fn ProxyConfig::http_forward(
  endpoint : @transport.Endpoint,
  identity_key? : String? = None,
) -> ProxyConfig {
  { mode: HttpForward, endpoint: Some(endpoint), identity_key, }
}

///|
pub fn ProxyConfig::https_connect(
  endpoint : @transport.Endpoint,
  identity_key? : String? = None,
) -> ProxyConfig {
  { mode: HttpsConnect, endpoint: Some(endpoint), identity_key, }
}

///|
pub fn ProxyConfig::mode(self : ProxyConfig) -> ProxyMode {
  self.mode
}

///|
pub fn ProxyConfig::endpoint(self : ProxyConfig) -> @transport.Endpoint? {
  self.endpoint
}

///|
pub fn ProxyConfig::identity_key(self : ProxyConfig) -> String? {
  self.identity_key
}

///|
pub fn ProxyConfig::validate(self : ProxyConfig) -> Result[Unit, ClientError] {
  match self.mode {
    Direct =>
      if self.endpoint is Some(_) {
        Err(ClientInvalidOptions("direct proxy cannot have an endpoint"))
      } else {
        Ok(())
      }
    HttpForward | HttpsConnect =>
      match self.endpoint {
        None => Err(ClientInvalidOptions("proxy mode requires an endpoint"))
        Some(endpoint) =>
          if endpoint.scheme() != "http" && endpoint.scheme() != "https" {
            Err(ClientInvalidOptions("proxy endpoint must use http or https"))
          } else {
            match self.identity_key {
              Some(value) if value.contains("\r") || value.contains("\n") =>
                Err(
                  ClientInvalidOptions("proxy identity contains a control byte"),
                )
              _ => Ok(())
            }
          }
      }
  }
}
