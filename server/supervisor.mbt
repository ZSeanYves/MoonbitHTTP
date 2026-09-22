///|
pub struct ServerSupervisor {
  config : ServerConfig
  mut state : ServerState
  mut active : Int
  mut accept_errors : Int
  mut next_connection_id : Int
  metrics : ServerMetrics
}

///|
pub fn ServerSupervisor::new(
  config? : ServerConfig = ServerConfig::defaults(),
) -> Result[ServerSupervisor, ServerError] {
  match config.validate() {
    Ok(_) =>
      Ok({
        config,
        state: Starting,
        active: 0,
        accept_errors: 0,
        next_connection_id: 0,
        metrics: ServerMetrics::new(),
      })
    Err(error) => Err(error)
  }
}

///|
pub fn ServerSupervisor::state(self : ServerSupervisor) -> ServerState {
  self.state
}

///|
pub fn ServerSupervisor::active_connections(self : ServerSupervisor) -> Int {
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
) -> Result[Int, ServerError] {
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
  connection_id : Int,
  handler_error : Error?,
) -> Unit {
  if self.active > 0 {
    self.active -= 1
  }
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
pub fn ServerSupervisor::record_accept_error(
  self : ServerSupervisor,
) -> Result[Unit, ServerError] {
  self.accept_errors += 1
  self.metrics.accept_errors += 1L
  (self.config.observer)(AcceptError(self.accept_errors))
  if self.accept_errors >= self.config.limits.max_accept_errors {
    self.state = Draining
    return Err(AcceptErrorLimitExceeded)
  }
  Ok(())
}

///|
pub fn ServerSupervisor::begin_shutdown(
  self : ServerSupervisor,
) -> Result[Unit, ServerError] {
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
  let group_result = @async.with_task_group(async fn(group) {
    while self.state == Running {
      let accepted = match listener.accept() {
        Ok(value) => value
        Err(_) =>
          match self.record_accept_error() {
            Ok(_) => continue
            Err(limit_error) => {
              listener.close()
              return Err(limit_error)
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
          return Err(error)
        }
      }
      ignore(
        group.spawn(async fn() {
          defer (connection.close)()
          let outcome = (connection.run)()
          match outcome {
            Ok(_) => self.release(id, None)
            Err(error) => self.release(id, Some(error))
          }
        }),
      )
    }
    listener.close()
    self.begin_shutdown() |> ignore
    Ok(())
  })
  match group_result {
    Ok(_) => self.finish_shutdown()
    Err(error) => Err(error)
  }
}
