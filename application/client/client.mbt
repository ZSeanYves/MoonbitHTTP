///|
pub struct Client {
  priv options : RequestOptions
  priv proxy : ProxyConfig
  priv tls : @transport.TlsOptions
  priv cookie_jar : @cookie.CookieJar
  priv cache : @cache.HttpCache
  priv mut cache_enabled : Bool
  priv wait : async (Int64) -> Unit
  priv authorize_redirect : (@types.Endpoint, @transport.PolicyOperation) -> Result[
    Unit,
    @transport.PolicyError,
  ]
  priv now_millis : () -> Int64
  priv auth : ClientAuthStore
  priv mut content_decoding : Bool
  priv content_coding_limits : @content_coding.ContentCodingLimits
  priv version : @types.Version
  priv exchange : async (@types.Request[IncomingBody]) -> @types.Response[
    IncomingBody,
  ]
  priv group : @async.TaskGroup
  priv wall_clock_seconds : () -> Int64
  priv refreshing : Set[(Int64, Bytes?, Bytes?)]
  priv bodies : Map[Int64, IncomingBody]
  priv mut next_id : Int64
  priv mut closed : Bool
}

///|
async fn client_default_wait(delay_ms : Int64) -> Unit {
  let bounded = delay_ms.max(0L).min(2147483647L)
  if bounded > 0L {
    @async.sleep(bounded.to_int())
  }
}

///|
pub async fn[X] with_client(
  run : async (Client) -> X,
  version~ : @types.Version,
  exchange~ : async (@types.Request[IncomingBody]) -> @types.Response[
    IncomingBody,
  ],
  wall_clock_seconds~ : () -> Int64,
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
) -> X {
  options.validate().unwrap_or_error()
  proxy.validate().unwrap_or_error()
  if version is (Http2 | Http3) && proxy.mode != Direct {
    raise ClientInvalidOptions("proxy requires HTTP/1")
  }
  // The endpoint supplies SNI/hostname identity when the caller leaves
  // `server_name` unset.  Validate syntax and certificate pairing here, then
  // perform the endpoint-specific hostname check in `send`.
  match tls.validate_common() {
    Ok(_) => ()
    Err(_) => raise ClientInvalidOptions("invalid TLS options")
  }
  match content_coding_limits.validate() {
    Ok(_) => ()
    Err(_) => raise ClientInvalidOptions("invalid content coding limits")
  }
  @async_support.with_group_result(async fn(group) {
    let client : Client = {
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
      version,
      exchange,
      group,
      wall_clock_seconds,
      refreshing: Set([]),
      bodies: Map([]),
      next_id: 0L,
      closed: false,
    }
    defer {
      client.closed = true
      for body in client.bodies.values().to_array() {
        body.cancel(ClientCancelled("client scope ended"))
      }
    }
    run(client)
  })
}

///|
pub fn Client::options(self : Client) -> RequestOptions {
  self.options
}

///|
pub fn Client::proxy(self : Client) -> ProxyConfig {
  self.proxy
}

///|
pub fn Client::tls(self : Client) -> @transport.TlsOptions {
  self.tls
}

///|
pub fn Client::set_cache_enabled(self : Client, enabled : Bool) -> Unit {
  self.cache_enabled = enabled
}

///|
/// Enables or disables automatic response content decoding. When enabled, the
/// client advertises the supported codings unless the caller supplied an
/// `Accept-Encoding` field.
pub fn Client::set_content_decoding(self : Client, enabled : Bool) -> Unit {
  self.content_decoding = enabled
}

///|
pub fn Client::content_decoding(self : Client) -> Bool {
  self.content_decoding
}

///|
pub fn Client::content_coding_limits(
  self : Client,
) -> @content_coding.ContentCodingLimits {
  self.content_coding_limits
}

///|
pub fn Client::cookie_jar(self : Client) -> @cookie.CookieJar {
  self.cookie_jar
}

///|
pub fn Client::cache(self : Client) -> @cache.HttpCache {
  self.cache
}

///|
pub fn Client::request(
  self : Client,
  http_method : @types.Method,
  uri : @types.Uri,
  body : Upload,
  headers~ : @types.HeaderMap = @types.HeaderMap::new(),
) -> @types.Request[Upload] {
  { http_method, uri, version: self.version, headers, body, }
}

///|
/// Send one logical request. Read or cancel the response within the client scope.
pub async fn Client::send(
  self : Client,
  request : @types.Request[Upload],
) -> @types.Response[IncomingBody] {
  defer request.body.discard_unopened()
  if self.closed {
    raise ClientCancelled("client scope ended")
  }
  if request.version != self.version {
    raise ClientInvalidOptions("request version differs from client version")
  }
  let start = (self.now_millis)().max(0L)
  let timeout = self.options.timeouts.total_ms
  let timeout_error = fn(ms : Int32) {
    ClientError::ClientTimeout(
      ClientTotal,
      ((self.now_millis)() - start).max(ms.to_int64()),
      client_deadline(start, ms),
    )
  }
  let mut waiting = true
  let mut pending : IncomingBody? = None
  let work = self.group.spawn(
    async fn() {
      let response = match timeout {
        None => self.send_inner(request)
        Some(ms) =>
          match
            @async.with_timeout_opt(ms, async fn() { self.send_inner(request) }) {
            Some(response) => response
            None => raise timeout_error(ms)
          }
      }
      if !waiting || self.closed {
        response.body.cancel(ClientCancelled("send cancelled"))
        raise ClientCancelled("send cancelled")
      }
      pending = Some(response.body)
      response
    },
    allow_failure=true,
    no_wait=true,
  )
  errdefer {
    waiting = false
    work.cancel()
    if pending is Some(body) {
      body.cancel(@body.BodyError::Cancelled)
    }
  }
  let response = work.wait()
  pending = None
  let source = response.body
  errdefer source.cancel(@body.BodyError::Cancelled)
  if self.closed {
    raise ClientCancelled("client scope ended")
  }
  let id = self.next_id
  self.next_id += 1L
  let mut timer : @async.Task[Unit]? = None
  let result = self.scoped_response(source, () => {
    self.bodies.remove(id)
    if timer is Some(task) {
      task.cancel()
    }
  })
  self.bodies.set(id, result)
  if timeout is Some(ms) {
    let remaining = (client_deadline(start, ms) - (self.now_millis)().max(start)).min(
      ms.to_int64(),
    )
    if remaining <= 0L {
      let error = timeout_error(ms)
      result.cancel(error)
      raise error
    }
    timer = Some(
      self.group.spawn(
        async fn() {
          @async.sleep(remaining.to_int())
          timer = None
          result.cancel(timeout_error(ms))
        },
        no_wait=true,
      ),
    )
  }
  response.map_body(_ => result)
}
