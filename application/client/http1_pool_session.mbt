///|
fn http1_pool_mode_identity(mode : ProxyMode) -> String {
  match mode {
    Direct => "direct"
    HttpForward => "forward"
    HttpsConnect => "connect"
  }
}

///|
fn Http1PooledRoundTripper::connection_key(
  self : Http1PooledRoundTripper,
  endpoint : ClientEndpoint,
) -> ConnectionKey {
  let proxy_endpoint = self.proxy.endpoint()
  let proxy_tls_identity = match proxy_endpoint {
    Some(value) if value.scheme() == "https" => self.proxy_tls_identity
    _ => "plain-proxy"
  }
  ConnectionKey::new(
    endpoint.transport,
    self.proxy.identity_key(),
    if endpoint.secure {
      Some(self.origin_tls_identity)
    } else {
      None
    },
    Http1,
    Some(http1_pool_mode_identity(self.proxy.mode()) + ":" + proxy_tls_identity),
    proxy_endpoint~,
  )
}

///|
async fn Http1PooledRoundTripper::open_session(
  self : Http1PooledRoundTripper,
  endpoint : ClientEndpoint,
  proxy_authorization : @types.HeaderValue?,
) -> Result[Http1PooledSession, ClientError] {
  if endpoint.secure && self.proxy.mode() == HttpForward {
    return Err(
      ClientInvalidOptions(
        "HTTPS origins require CONNECT rather than forward-proxy absolute form",
      ),
    )
  }
  let mut proxy_target : @types.Endpoint? = None
  let channel = match self.proxy.mode() {
    Direct => {
      match self.authorize_endpoint(endpoint.transport, Resolve) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      match self.connect_stream(endpoint.transport) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
    }
    HttpForward | HttpsConnect => {
      let proxy_endpoint = match self.proxy.endpoint() {
        Some(value) => value
        None => return Err(ClientInvalidOptions("proxy endpoint is missing"))
      }
      match self.authorize_endpoint(proxy_endpoint, Resolve) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      match self.authorize_endpoint(proxy_endpoint, ProxyConnect) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      let target = match self.authorize_proxy_origin(endpoint.transport) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      proxy_target = Some(target)
      let raw = match self.connect_stream(proxy_endpoint) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if proxy_endpoint.scheme() == "https" {
        match self.secure_stream(raw, proxy_endpoint, self.proxy_tls) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
      } else {
        raw
      }
    }
  }
  let routed = match self.proxy.mode() {
    HttpsConnect =>
      match
        http1_pool_connect_tunnel(
          channel,
          match proxy_target {
            Some(value) => value
            None => endpoint.transport
          },
          proxy_authorization,
          self.options.limits,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
    Direct | HttpForward => channel
  }
  let stream = if endpoint.secure {
    match self.secure_stream(routed, endpoint.transport, self.origin_tls) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  } else {
    routed
  }
  Http1PooledSession::new(stream, self.options, proxy_target~)
}

///|
fn Http1PooledRoundTripper::close_evicted(
  self : Http1PooledRoundTripper,
) -> Unit {
  for id in self.pool.take_evicted_ids() {
    match self.sessions.get(id) {
      Some(session) => {
        self.sessions.remove(id)
        session.close()
      }
      None => ()
    }
  }
}

///|
fn http1_pool_error(error : PoolError) -> ClientError {
  match error {
    InvalidLimits => ClientInvalidOptions("invalid connection pool limits")
    AtCapacity => ClientProtocol("connection pool capacity accounting failed")
    UnknownLease => ClientProtocol("connection pool lost a lease")
    LeaseAlreadyReleased =>
      ClientProtocol("connection lease was released twice")
    LeaseInUse => ClientProtocol("active connection lease cannot be removed")
    IdExhausted => ClientProtocol("connection pool identifier space exhausted")
  }
}

///|
async fn Http1PooledRoundTripper::acquire_session(
  self : Http1PooledRoundTripper,
  key : ConnectionKey,
  endpoint : ClientEndpoint,
  proxy_authorization : @types.HeaderValue?,
) -> Result[(PoolLease, Http1PooledSession), ClientError] {
  self.slots.acquire()
  if self.closed {
    self.slots.release()
    return Err(ClientCancelled("HTTP/1 executor is closed"))
  }
  let acquired = match self.pool.acquire(key) {
    Ok(value) => value
    Err(error) => {
      self.slots.release()
      return Err(http1_pool_error(error))
    }
  }
  let (lease, created) = match acquired {
    Created(id) => ({ key, id, released: false, }, true)
    Reused(id) => ({ key, id, released: false, }, false)
  }
  self.close_evicted()
  let mut transferred = false
  defer (if !transferred {
    ignore(self.pool.release_lease(lease, false))
    self.close_evicted()
    self.slots.release()
  })
  if !created {
    match self.sessions.get(lease.id()) {
      Some(session) => {
        transferred = true
        return Ok((lease, session))
      }
      None => return Err(ClientProtocol("connection pool session is missing"))
    }
  }
  let session = match self.open_session(endpoint, proxy_authorization) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  // `close()` may run while DNS, TCP, or TLS creation is suspended. Do not
  // publish a newly opened session after that lifecycle boundary.
  if self.closed {
    session.close()
    return Err(ClientCancelled("HTTP/1 executor is closed"))
  }
  self.sessions.set(lease.id(), session)
  transferred = true
  Ok((lease, session))
}

///|
fn Http1PooledRoundTripper::finish_lease(
  self : Http1PooledRoundTripper,
  lease : PoolLease,
  session : Http1PooledSession,
  reusable : Bool,
) -> Unit {
  if lease.is_released() {
    return
  }
  let reusable = reusable && !self.closed && session.is_reusable()
  match self.pool.release_lease(lease, reusable) {
    Ok(_) => ()
    Err(_) => {
      lease.released = true
      self.sessions.remove(lease.id())
      session.close()
    }
  }
  self.close_evicted()
  self.slots.release()
}

///|
/// Stops new acquisitions and closes every physical session, including
/// active response bodies. The operation is idempotent.
pub fn Http1PooledRoundTripper::close(self : Http1PooledRoundTripper) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  for session in self.sessions.values() {
    session.close()
  }
  self.sessions.clear()
}

///|
pub fn Http1PooledRoundTripper::connection_count(
  self : Http1PooledRoundTripper,
) -> Int {
  self.sessions.length()
}

///|
pub fn Http1PooledRoundTripper::idle_connection_count(
  self : Http1PooledRoundTripper,
) -> Int {
  self.pool.idle_len()
}
