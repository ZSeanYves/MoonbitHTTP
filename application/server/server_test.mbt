///|
struct PolicyRejectingListener {
  mut remaining : Int
}

///|
pub impl @server.Listener for PolicyRejectingListener with fn accept(self) {
  if self.remaining > 0 {
    self.remaining -= 1
    return Err(Policy(Denied(Accept, "peer rejected")))
  }
  Ok(None)
}

///|
pub impl @server.Listener for PolicyRejectingListener with fn close(_self) {
  ()
}

///|
test "server supervisor: limits and idempotent drain are observable" {
  let events : Array[@server.ServerEvent] = []
  let config = @server.ServerConfig::defaults().with_observer(fn(event) {
    events.push(event)
  })
  let supervisor = @server.ServerSupervisor::new(config~).unwrap()
  supervisor.start().unwrap()
  let first = supervisor.try_acquire().unwrap()
  assert_eq(supervisor.active_connections(), 1)
  supervisor.begin_shutdown().unwrap()
  assert_true(supervisor.try_acquire() is Err(NotRunning))
  supervisor.release(first, None)
  supervisor.finish_shutdown().unwrap()
  assert_eq(supervisor.state(), Stopped)
  assert_true(events.length() >= 5)
}

///|
async test "server supervisor: policy rejections do not exhaust accept budget" {
  let limits : @server.ServerLimits = {
    ..@server.ServerLimits::defaults(),
    max_accept_errors: 1,
  }
  let supervisor = @server.ServerSupervisor::new(
    config=@server.ServerConfig::defaults().with_limits(limits),
  ).unwrap()
  let listener = PolicyRejectingListener::{ remaining: 32, }
  assert_eq(supervisor.serve(listener), Ok(()))
  assert_eq(supervisor.state(), Stopped)
  assert_eq(supervisor.metrics().accept_errors(), 0L)
}

///|
test "server supervisor: concurrent cap and accept error budget are finite" {
  let limits : @server.ServerLimits = {
    ..@server.ServerLimits::defaults(),
    max_connections: 1,
    max_accept_errors: 2,
  }
  let supervisor = @server.ServerSupervisor::new(
    config=@server.ServerConfig::defaults().with_limits(limits),
  ).unwrap()
  supervisor.start().unwrap()
  let first = supervisor.try_acquire().unwrap()
  assert_true(supervisor.try_acquire() is Err(ConnectionLimit))
  supervisor.release(first, None)
  assert_eq(supervisor.record_accept_error(), Ok(()))
  assert_true(supervisor.record_accept_error() is Err(AcceptErrorLimitExceeded))
  assert_eq(supervisor.state(), Draining)
}
