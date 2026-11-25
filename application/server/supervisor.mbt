///|
pub struct ServerSupervisor {
  config : ServerConfig
  mut state : ServerState
  mut active : Int32
  priv mut last_accept_failure : ServerError?
  mut accept_errors : Int32
  mut next_connection_id : Int32
  metrics : ServerMetrics
  connections_changed : @async.Cond
  mut drain_listener : (() -> Unit)?
  mut close_listener : (() -> Unit)?
  mut cancel_accept : (() -> Unit)?
}

///|
pub fn ServerSupervisor::new(
  config~ : ServerConfig = ServerConfig::defaults(),
) -> Result[ServerSupervisor, ServerError] {
  match config.validate() {
    Ok(_) =>
      Ok({
        config,
        state: Starting,
        active: 0,
        accept_errors: 0,
        last_accept_failure: None,
        next_connection_id: 0,
        metrics: ServerMetrics::new(),
        connections_changed: Cond(),
        drain_listener: None,
        close_listener: None,
        cancel_accept: None,
      })
    Err(error) => Err(error)
  }
}

///|
pub fn ServerSupervisor::state(self : ServerSupervisor) -> ServerState {
  self.state
}

///|
pub fn ServerSupervisor::active_connections(self : ServerSupervisor) -> Int32 {
  self.active
}

///|
pub fn ServerSupervisor::metrics(self : ServerSupervisor) -> ServerMetrics {
  self.metrics
}

///|
pub fn ServerSupervisor::start(
  self : ServerSupervisor,
) -> Result[Unit, ServerError] {
  if self.state != Starting {
    return Err(AlreadyRunning)
  }
  self.state = Running
  (self.config.observer)(StateChanged(Running))
  Ok(())
}

///|
pub fn ServerSupervisor::try_acquire(
  self : ServerSupervisor,
) -> Result[Int32, ServerError] {
  if self.state != Running {
    return Err(NotRunning)
  }
  if self.active >= self.config.limits.max_connections {
    self.metrics.rejected += 1L
    (self.config.observer)(RejectedAtCapacity)
    return Err(ConnectionLimit)
  }
  let id = self.next_connection_id
  self.next_connection_id += 1
  self.active += 1
  self.metrics.accepted += 1L
  (self.config.observer)(Accepted(id))
  (self.config.observer)(ConnectionStarted(id))
  Ok(id)
}

///|
pub fn ServerSupervisor::release(
  self : ServerSupervisor,
  connection_id : Int32,
  handler_error : Error?,
) -> Unit {
  if self.active > 0 {
    self.active -= 1
  }
  self.connections_changed.broadcast()
  match handler_error {
    Some(error) => {
      self.metrics.handler_errors += 1L
      (self.config.error_responder)(error)
      (self.config.observer)(HandlerError(connection_id))
    }
    None => self.metrics.completed += 1L
  }
  (self.config.observer)(ConnectionFinished(connection_id))
}

///|
/// Most recent listener failure, including the failure that exhausted the budget.
pub fn ServerSupervisor::last_accept_error(
  self : ServerSupervisor,
) -> ServerError? {
  self.last_accept_failure
}

///|
pub fn ServerSupervisor::record_accept_error(
  self : ServerSupervisor,
) -> Result[Unit, ServerError] {
  self.accept_errors += 1
  self.metrics.accept_errors += 1L
  (self.config.observer)(AcceptError(self.accept_errors))
  if self.accept_errors >= self.config.limits.max_accept_errors {
    self.begin_shutdown() |> ignore
    return Err(AcceptErrorLimitExceeded)
  }
  Ok(())
}

///|
pub fn ServerSupervisor::begin_shutdown(
  self : ServerSupervisor,
) -> Result[Unit, ServerError] {
  if self.drain_listener is Some(drain) {
    self.drain_listener = None
    drain()
  }
  // A pending Windows AcceptEx needs the listening handle until its
  // cancellation completion is delivered. The accept loop closes it after
  // joining the task. Repeated shutdown calls follow the same ordering.
  if self.cancel_accept is Some(cancel) {
    cancel()
  } else if self.close_listener is Some(close) {
    self.close_listener = None
    close()
  }
  match self.state {
    Stopped => Ok(())
    Draining => Ok(())
    Starting | Running => {
      self.state = Draining
      (self.config.observer)(ShutdownStarted)
      (self.config.observer)(StateChanged(Draining))
      Ok(())
    }
  }
}

///|
pub fn ServerSupervisor::finish_shutdown(
  self : ServerSupervisor,
) -> Result[Unit, ServerError] {
  if self.state == Stopped {
    return Ok(())
  }
  if self.active != 0 {
    return Err(ShutdownTimeout)
  }
  self.state = Stopped
  (self.config.observer)(ShutdownFinished)
  (self.config.observer)(StateChanged(Stopped))
  Ok(())
}

///|
pub async fn[L : Listener] ServerSupervisor::serve(
  self : ServerSupervisor,
  listener : L,
) -> Result[Unit, ServerError] {
  match self.start() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  self.close_listener = Some(fn() { listener.close() })
  self.drain_listener = Some(fn() { listener.begin_drain() })
  let cleanups : Map[Int32, () -> Unit] = Map([])
  let mut pending_accept : AcceptedConnection? = None
  defer {
    // Cancellation can arrive after accept acquires a connection but before
    // the serving task receives and registers it.
    if pending_accept is Some(connection) {
      (connection.close)()
    }
    // A task cancelled before its first turn may not install its own defer.
    // The owner retains cleanup until the child has actually released it.
    let remaining : Array[() -> Unit] = []
    for _, cleanup in cleanups {
      remaining.push(cleanup)
    }
    for cleanup in remaining {
      cleanup()
    }
    // The group has joined its children, including an interrupted accept.
    self.cancel_accept = None
    self.begin_shutdown() |> ignore
    if self.state != Stopped && self.active == 0 {
      self.finish_shutdown() |> ignore
    }
  }
  let mut outcome : Result[Unit, ServerError] = Ok(())
  @async.with_task_group(async fn(group) {
    while self.state == Running {
      let accepting = group.spawn(
        async fn() {
          let accepted = listener.accept()
          if accepted is Ok(Some(connection)) {
            pending_accept = Some(connection)
          }
          accepted
        },
        no_wait=true,
        allow_failure=true,
      )
      self.cancel_accept = Some(fn() { accepting.cancel() })
      if self.state != Running {
        accepting.cancel()
      }
      let accepted_result = accepting.wait() catch {
        @async.WaitedTaskAlreadyCancelled if self.state != Running => Ok(None)
        error => raise error
      }
      self.cancel_accept = None
      pending_accept = None
      if self.state != Running {
        if accepted_result is Ok(Some(connection)) {
          (connection.close)()
        }
        break
      }
      let accepted = match accepted_result {
        Ok(value) => value
        // A restrictive peer policy is an expected rejection after accept;
        // it must not consume the fatal accept-error budget. Otherwise a
        // remote can open denied connections until the listener drains.
        Err(Policy(_)) => continue
        Err(cause) => {
          self.last_accept_failure = Some(cause)
          match self.record_accept_error() {
            Ok(_) => continue
            Err(limit_error) => {
              outcome = Err(limit_error)
              break
            }
          }
        }
      }
      guard accepted is Some(connection) else {
        self.begin_shutdown() |> ignore
        break
      }
      let id = match self.try_acquire() {
        Ok(value) => value
        Err(ConnectionLimit) => {
          (connection.close)()
          continue
        }
        Err(error) => {
          (connection.close)()
          outcome = Err(error)
          break
        }
      }
      let mut handler_error : Error? = None
      let cleanup = fn() {
        if cleanups.contains(id) {
          cleanups.remove(id)
          (connection.close)()
          self.release(id, handler_error)
        }
      }
      cleanups.set(id, cleanup)
      ignore(
        group.spawn(
          async fn() {
            defer cleanup()
            // Cancellation is a separate async effect and still propagates.
            // Ordinary raised errors belong to this peer, just like Result.Err.
            let result = (connection.run)() catch { error => Err(error) }
            if result is Err(error) {
              handler_error = Some(error)
            }
          },
          no_wait=true,
        ),
      )
    }
    self.begin_shutdown() |> ignore
    if outcome is Err(_) {
      return
    }
    let drain = async fn() {
      while self.active > 0 {
        self.connections_changed.wait()
      }
    }
    match self.config.limits.graceful_timeout_ms {
      Some(timeout) =>
        @async.with_timeout(timeout, drain) catch {
          @async.TimeoutError => outcome = Err(ShutdownTimeout)
          error => raise error
        }
      None => drain()
    }
  })
  match outcome {
    Ok(_) => self.finish_shutdown()
    Err(error) => Err(error)
  }
}
