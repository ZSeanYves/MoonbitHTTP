///|
pub(all) enum ServerState {
  Starting
  Running
  Draining
  Stopped
} derive(Eq, Debug)

///|
pub(all) enum ServerPhase {
  Accept
  Connection
  Handler
  Shutdown
} derive(Eq, Debug)

///|
pub(all) suberror ServerError {
  InvalidConfig(String)
  AlreadyRunning
  NotRunning
  ConnectionLimit
  AcceptFailed(String)
  AcceptErrorLimitExceeded
  HandlerFailed(String)
  ShutdownTimeout
  Closed
} derive(Eq, Debug)

///|
pub(all) struct ServerLimits {
  max_connections : Int
  max_accept_errors : Int
  graceful_timeout_ms : Int?
} derive(Eq, Debug)

///|
pub fn ServerLimits::defaults() -> ServerLimits {
  {
    max_connections: 1024,
    max_accept_errors: 16,
    graceful_timeout_ms: Some(30000),
  }
}

///|
pub fn ServerLimits::validate(self : ServerLimits) -> Result[Unit, ServerError] {
  if self.max_connections < 1 || self.max_accept_errors < 1 {
    return Err(InvalidConfig("server limits must be positive"))
  }
  match self.graceful_timeout_ms {
    Some(value) if value <= 0 =>
      Err(InvalidConfig("graceful timeout must be positive"))
    _ => Ok(())
  }
}

///|
pub(all) enum ServerEvent {
  StateChanged(ServerState)
  Accepted(Int)
  RejectedAtCapacity
  AcceptError(Int)
  ConnectionStarted(Int)
  ConnectionFinished(Int)
  HandlerError(Int)
  ShutdownStarted
  ShutdownFinished
} derive(Eq, Debug)

///|
pub(all) struct ServerMetrics {
  mut accepted : Int64
  mut rejected : Int64
  mut accept_errors : Int64
  mut completed : Int64
  mut handler_errors : Int64
} derive(Eq, Debug)

///|
pub fn ServerMetrics::new() -> ServerMetrics {
  {
    accepted: 0L,
    rejected: 0L,
    accept_errors: 0L,
    completed: 0L,
    handler_errors: 0L,
  }
}

///|
pub fn ServerMetrics::accepted(self : ServerMetrics) -> Int64 {
  self.accepted
}

///|
pub fn ServerMetrics::rejected(self : ServerMetrics) -> Int64 {
  self.rejected
}

///|
pub fn ServerMetrics::accept_errors(self : ServerMetrics) -> Int64 {
  self.accept_errors
}

///|
pub fn ServerMetrics::completed(self : ServerMetrics) -> Int64 {
  self.completed
}

///|
pub fn ServerMetrics::handler_errors(self : ServerMetrics) -> Int64 {
  self.handler_errors
}

///|
/// A listener returns an already capability-bound connection. The supervisor
/// owns the task lifetime and calls `close` when draining or cancelling.
pub(all) struct AcceptedConnection {
  run : async () -> Result[Unit, Error]
  close : () -> Unit
}

///|
pub fn AcceptedConnection::new(
  run : async () -> Result[Unit, Error],
  close : () -> Unit,
) -> AcceptedConnection {
  { run, close, }
}

///|
pub(open) trait Listener {
  async fn accept(Self) -> Result[AcceptedConnection?, ServerError]
  fn close(Self) -> Unit
}

///|
pub struct ServerConfig {
  limits : ServerLimits
  observer : (ServerEvent) -> Unit
  error_responder : (Error) -> Unit
}

///|
pub fn ServerConfig::defaults() -> ServerConfig {
  {
    limits: ServerLimits::defaults(),
    observer: fn(_) { () },
    error_responder: fn(_) { () },
  }
}

///|
pub fn ServerConfig::validate(self : ServerConfig) -> Result[Unit, ServerError] {
  self.limits.validate()
}

///|
pub fn ServerConfig::with_limits(
  self : ServerConfig,
  limits : ServerLimits,
) -> ServerConfig {
  { ..self, limits, }
}

///|
pub fn ServerConfig::with_observer(
  self : ServerConfig,
  observer : (ServerEvent) -> Unit,
) -> ServerConfig {
  { ..self, observer, }
}

///|
pub fn ServerConfig::with_error_responder(
  self : ServerConfig,
  responder : (Error) -> Unit,
) -> ServerConfig {
  { ..self, error_responder: responder, }
}
