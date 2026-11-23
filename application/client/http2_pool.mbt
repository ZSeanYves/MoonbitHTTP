///|
priv enum Http2SessionState {
  Opening
  Ready(@service.H2Client)
  Rejected(ClientError)
  Failed(Error)
}

///|
priv struct Http2Session {
  origin : String
  mut state : Http2SessionState
  mut retiring : Bool
  // Includes callers waiting for initial SETTINGS or for a peer stream slot.
  mut users : Int
  mut worker : @async.Task[Unit]?
}

///|
/// Scoped, direct-origin HTTP/2 executor. Each live origin shares a multiplexed session.
pub struct Http2Client {
  priv dialer : ClientDialer
  priv tls : @transport.TlsOptions
  priv config : @service.H2ClientConfig
  priv max_connections : Int
  priv sessions : Array[Http2Session]
  priv changed : @cond_var.Cond
  priv spawn : (async () -> Unit) -> @async.Task[Unit]
  priv mut closed : Bool
}

///|
pub(all) struct Http2PoolOptions {
  max_connections : Int
  session : @service.H2ClientConfig
  tls : @transport.TlsOptions
  connect_options : @transport.ConnectOptions
  resolve_options : @transport.ResolveOptions
  tls_timeout_ms : Int?
}

///|
pub fn Http2PoolOptions::defaults() -> Http2PoolOptions {
  {
    max_connections: 32,
    session: @service.H2ClientConfig::defaults(),
    tls: @transport.TlsOptions::defaults(),
    connect_options: @transport.ConnectOptions::defaults(),
    resolve_options: @transport.ResolveOptions::defaults(),
    tls_timeout_ms: Some(10000),
  }
}

///|
/// Open a bounded pool with explicit DNS, numeric connection policy, TLS and clock capabilities.
/// HTTPS requires h2 ALPN. Cleartext HTTP uses HTTP/2 prior knowledge.
pub async fn[
  C : @transport.StreamConnector,
  R : @transport.NameResolver,
  T : @transport.TlsProvider,
  P : @transport.NetworkPolicy,
  K : @transport.Clock,
  X,
] with_http2_client(
  connector : C,
  resolver : R,
  tls_provider : T,
  policy : P,
  clock : K,
  run : async (Http2Client) -> X,
  options? : Http2PoolOptions = Http2PoolOptions::defaults(),
) -> X {
  let {
    max_connections,
    session: config,
    tls,
    connect_options,
    resolve_options,
    tls_timeout_ms,
  } = options
  if max_connections <= 0 {
    raise ClientInvalidOptions("HTTP/2 pool capacity must be positive")
  }
  if config.validate() is Err(_) {
    raise ClientInvalidOptions("invalid HTTP/2 session configuration")
  }
  if tls.validate_common() is Err(_) {
    raise ClientInvalidOptions("invalid origin TLS options")
  }
  let network = ClientNetwork::from_capabilities(
    connector, resolver, tls_provider, policy, clock,
  )
  let dialer = match
    ClientDialer::new(network, connect_options, resolve_options, tls_timeout_ms) {
    Ok(value) => value
    Err(error) => raise error
  }
  @async.with_task_group(async fn(group) {
    let client : Http2Client = {
      dialer,
      tls,
      config,
      max_connections,
      sessions: [],
      changed: Cond(),
      spawn: fn(task) { group.spawn(task, allow_failure=true) },
      closed: false,
    }
    defer client.close()
    run(client)
  })
}

///|
pub fn Http2Client::close(self : Http2Client) -> Unit {
  if !self.closed {
    self.closed = true
    for entry in self.sessions {
      if entry.worker is Some(worker) {
        worker.cancel()
      }
    }
    self.changed.broadcast()
  }
}

///|
/// Count opening, usable and draining connections against the same bound.
pub fn Http2Client::connection_count(self : Http2Client) -> Int {
  self.sessions.length()
}

///|
async fn Http2Client::drive(
  self : Http2Client,
  entry : Http2Session,
  endpoint : ClientEndpoint,
) -> Unit {
  defer {
    entry.worker = None
    for index in 0..<self.sessions.length() {
      if physical_equal(self.sessions[index], entry) {
        ignore(self.sessions.remove(index))
        break
      }
    }
    self.changed.broadcast()
  }
  let connection = match
    self.dialer.open_direct(endpoint, self.tls, alpn="h2") {
    Ok(value) => value
    Err(error) => {
      entry.state = Rejected(error)
      return
    }
  }
  defer connection.close()
  let io = ClientStreamIo::new(connection)
  @service.with_h2_client_connection(
    io,
    io,
    async fn(client) {
      client.wait_for_settings()
      entry.state = Ready(client)
      self.changed.broadcast()
      // GOAWAY makes the session unavailable to newcomers immediately. Keep the
      // socket for accepted streams until both halves have finished.
      while !entry.retiring && (client.accepts_requests() || !client.is_idle()) {
        self.changed.wait()
      }
    },
    config=self.config,
    on_state_change=fn() { self.changed.broadcast() },
  )
}

///|
async fn Http2Client::reserve(
  self : Http2Client,
  endpoint : ClientEndpoint,
) -> Http2Session? {
  while !self.closed {
    let mut evict : Http2Session? = None
    for entry in self.sessions {
      if entry.retiring {
        continue
      }
      match entry.state {
        Opening if entry.origin == endpoint.origin => {
          entry.users += 1
          return Some(entry)
        }
        Ready(client) if client.accepts_requests() => {
          if entry.origin == endpoint.origin {
            entry.users += 1
            return Some(entry)
          }
          if entry.users == 0 && client.is_idle() && evict is None {
            evict = Some(entry)
          }
        }
        _ => ()
      }
    }
    if self.sessions.length() < self.max_connections {
      let entry : Http2Session = {
        origin: endpoint.origin,
        state: Opening,
        users: 1,
        retiring: false,
        worker: None,
      }
      self.sessions.push(entry)
      entry.worker = Some(
        (self.spawn)(async fn() {
          self.drive(entry, endpoint) catch {
            error => {
              entry.state = Failed(error)
              self.changed.broadcast()
            }
          }
        }),
      )
      return Some(entry)
    }
    if evict is Some(entry) {
      entry.retiring = true
      self.changed.broadcast()
    }
    self.changed.wait()
  }
  None
}
