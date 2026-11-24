///|
struct PolicyRejectingListener {
  mut remaining : Int32
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
