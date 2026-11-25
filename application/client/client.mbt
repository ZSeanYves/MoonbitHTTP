///|
priv struct ClientConfig {
  options : RequestOptions
  proxy : ProxyConfig
  tls : @transport.TlsOptions
  cookie_jar : @cookie.CookieJar
  cache : @cache.HttpCache
  mut cache_enabled : Bool
  wait : async (Int64) -> Unit
  authorize_redirect : (@types.Endpoint, @transport.PolicyOperation) -> Result[
    Unit,
    @transport.PolicyError,
  ]
  now_millis : () -> Int64
  auth : ClientAuthStore
  mut content_decoding : Bool
  content_coding_limits : @content_coding.ContentCodingLimits
}

///|
pub struct Client {
  priv config : ClientConfig
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
  options~ : RequestOptions = RequestOptions::defaults(),
  proxy~ : ProxyConfig = ProxyConfig::direct(),
  tls~ : @transport.TlsOptions = @transport.TlsOptions::defaults(),
  cookie_jar~ : @cookie.CookieJar = @cookie.CookieJar::new().unwrap(),
  cache~ : @cache.HttpCache = @cache.HttpCache::new().unwrap(),
  cache_enabled~ : Bool = false,
  wait~ : async (Int64) -> Unit = client_default_wait,
  authorize_redirect~ : (@types.Endpoint, @transport.PolicyOperation) -> Result[
    Unit,
    @transport.PolicyError,
  ],
  now_millis~ : () -> Int64,
  content_decoding~ : Bool = false,
  content_coding_limits~ : @content_coding.ContentCodingLimits = @content_coding.ContentCodingLimits::defaults(),
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
pub fn Client::tls(self : Client) -> @transport.TlsOptions {
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
      match
        @async.with_timeout_opt(timeout, async fn() {
          self.send_inner(executor, request, now_seconds)
        }) {
        Some(result) => result
        None => {
          let elapsed = ((self.config.now_millis)().max(started) - started).max(
            timeout.to_int64(),
          )
          Err(
            ClientTimeout(
              ClientTotal,
              elapsed,
              client_deadline(started, timeout),
            ),
          )
        }
      }
    }
  }
}
