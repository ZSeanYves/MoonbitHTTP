///|
priv enum OriginSessionState[S] {
  Opening
  Ready(S)
  Rejected(ClientError)
  Failed(Error)
}

///|
priv struct OriginSession[S] {
  origin : String
  expansion : Bool
  mut state : OriginSessionState[S]
  // A burst for one origin needs only one idle connection to make room.
  mut retiring_for : String?
  // Includes callers waiting for a handshake or for a peer stream slot.
  mut users : Int32
  mut worker : @async.Task[Unit]?
}

///|
priv struct OriginPool[S] {
  max_connections : Int32
  max_connections_per_origin : Int32
  has_capacity : (S) -> Bool
  sessions : Array[OriginSession[S]]
  changed : @cond_var.Cond
  spawn : (async () -> Unit) -> @async.Task[Unit]
  open : async (ClientEndpoint, async (S) -> Unit, () -> Unit) -> Result[
    Unit,
    ClientError,
  ]
  accepts : (S) -> Bool
  idle : (S) -> Bool
  closed_error : ClientError
  mut closed : Bool
}

///|
async fn[S, X] with_origin_pool(
  protocol_name : String,
  max_connections : Int32,
  open : async (ClientEndpoint, async (S) -> Unit, () -> Unit) -> Result[
    Unit,
    ClientError,
  ],
  accepts : (S) -> Bool,
  idle : (S) -> Bool,
  run : async (OriginPool[S]) -> X,
  max_connections_per_origin~ : Int32 = 1,
  has_capacity~ : (S) -> Bool = _ => true,
) -> X {
  if max_connections <= 0 || max_connections_per_origin <= 0 {
    raise ClientInvalidOptions(
      protocol_name + " pool capacity must be positive",
    )
  }
  @async_support.with_group_result(async fn(group) {
    let pool : OriginPool[S] = {
      max_connections,
      max_connections_per_origin,
      has_capacity,
      open,
      accepts,
      idle,
      sessions: [],
      changed: Cond(),
      spawn: task => group.spawn(task, allow_failure=true),
      closed_error: ClientCancelled(protocol_name + " client is closed"),
      closed: false,
    }
    defer pool.close()
    run(pool)
  })
}

///|
fn[S] OriginPool::close(self : OriginPool[S]) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  for entry in self.sessions {
    entry.retiring_for = Some(entry.origin)
    match entry.state {
      Ready(client) if (self.idle)(client) && entry.users == 0 => ()
      _ => if entry.worker is Some(worker) { worker.cancel() }
    }
  }
  self.changed.broadcast()
}

///|
async fn[S] OriginPool::drive(
  self : OriginPool[S],
  entry : OriginSession[S],
  endpoint : ClientEndpoint,
) -> Unit {
  defer {
    entry.worker = None
    // A completed worker can no longer serve an admitted or waiting caller.
    // The client holds a change notification back into this pool.
    if entry.state is Ready(_) {
      entry.state = Rejected(self.closed_error)
    }
    for index in 0..<self.sessions.length() {
      if physical_equal(self.sessions[index], entry) {
        ignore(self.sessions.remove(index))
        break
      }
    }
    self.changed.broadcast()
  }
  let changed = self.changed
  let result = (self.open)(
    endpoint,
    async fn(client) {
      entry.state = Ready(client)
      self.changed.broadcast()
      // After GOAWAY, retain accepted streams until their bodies are released.
      while entry.retiring_for is None &&
            ((self.accepts)(client) || !(self.idle)(client)) {
        self.changed.wait()
      }
      if entry.retiring_for is None {
        entry.retiring_for = Some(entry.origin)
      }
    },
    () => changed.broadcast(),
  )
  match result {
    Err(error) => entry.state = Rejected(error)
    Ok(_) if entry.state is Opening =>
      entry.state = Rejected(
        ClientProtocol("connection closed before becoming ready"),
      )
    _ => ()
  }
}

///|
async fn[S] OriginPool::reserve(
  self : OriginPool[S],
  endpoint : ClientEndpoint,
  expansion_wait : async (async () -> Unit) -> Unit,
) -> OriginSession[S]? {
  while !self.closed {
    let mut evict : OriginSession[S]? = None
    let mut replacement_pending = false
    let mut origin_ready = 0
    let mut opening : OriginSession[S]? = None
    let mut saturated : OriginSession[S]? = None
    for entry in self.sessions {
      if entry.retiring_for is Some(origin) {
        replacement_pending = replacement_pending || origin == endpoint.origin
        continue
      }
      match entry.state {
        Opening if entry.origin == endpoint.origin => opening = Some(entry)
        Ready(client) if (self.accepts)(client) => {
          if entry.origin == endpoint.origin {
            origin_ready += 1
            if self.max_connections_per_origin == 1 ||
              (self.has_capacity)(client) {
              entry.users += 1
              return Some(entry)
            }
            if saturated is None ||
              (saturated is Some(previous) && entry.users < previous.users) {
              saturated = Some(entry)
            }
            continue
          }
          if entry.users == 0 && (self.idle)(client) && evict is None {
            evict = Some(entry)
          }
        }
        _ => ()
      }
    }
    if opening is Some(entry) {
      entry.users += 1
      return Some(entry)
    }
    if saturated is Some(_) &&
      replacement_pending &&
      origin_ready < self.max_connections_per_origin &&
      self.sessions.length() >= self.max_connections {
      // A cancelled opener is releasing its global slot. Do not strand its
      // successor behind an unrelated long-lived stream on the old session.
      expansion_wait(() => self.changed.wait())
      continue
    }
    if saturated is Some(entry) &&
      (
        origin_ready >= self.max_connections_per_origin ||
        self.sessions.length() >= self.max_connections
      ) {
      entry.users += 1
      return Some(entry)
    }
    if self.sessions.length() < self.max_connections {
      let entry : OriginSession[S] = {
        origin: endpoint.origin,
        expansion: saturated is Some(_),
        state: Opening,
        users: 1,
        retiring_for: None,
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
    if !replacement_pending && evict is Some(entry) {
      entry.retiring_for = Some(endpoint.origin)
      self.changed.broadcast()
    }
    self.changed.wait()
  }
  None
}

///|
async fn[S, B : @body.Body, X] OriginPool::exchange(
  self : OriginPool[S],
  request : @types.Request[B],
  send : async (S, @types.Request[B]) -> X,
  validate_origin~ : (ClientEndpoint) -> Unit raise = _ => (),
  expansion_wait~ : async (async () -> Unit) -> Unit = work => work(),
) -> Result[X, ClientError] {
  let mut submitted = false
  defer (if !submitted { request.body.cancel(@body.BodyError::Cancelled) })
  let endpoint = match ClientEndpoint::from_uri(request.uri) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  validate_origin(endpoint)
  guard self.reserve(endpoint, expansion_wait) is Some(entry) else {
    return Err(self.closed_error)
  }
  defer {
    entry.users -= 1
    if entry.users == 0 {
      if entry.state is Opening && entry.worker is Some(worker) {
        entry.retiring_for = Some(entry.origin)
        worker.cancel()
      }
      self.changed.broadcast()
    }
  }
  if entry.expansion && entry.state is Opening {
    expansion_wait(async fn() {
      while !self.closed && entry.state is Opening {
        self.changed.wait()
      }
    })
  }
  while !self.closed {
    match entry.state {
      Opening => self.changed.wait()
      Rejected(error) => return Err(error)
      Failed(error) => raise error
      Ready(client) => {
        submitted = true
        return Ok(send(client, request))
      }
    }
  }
  Err(self.closed_error)
}
