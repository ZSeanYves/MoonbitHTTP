///|
struct LifecycleListener {
  pending : Array[@server.AcceptedConnection]
  signal : @async.CondVar
  keep_open : Bool
  fail_accept : Bool
  mut waiting : Bool
  mut closed : Bool
  mut close_calls : Int
  mut before_return : (() -> Unit)?
}

///|
fn LifecycleListener::new(
  pending : Array[@server.AcceptedConnection],
  keep_open? : Bool = false,
  fail_accept? : Bool = false,
) -> LifecycleListener {
  {
    pending,
    signal: Cond(),
    keep_open,
    fail_accept,
    waiting: false,
    closed: false,
    close_calls: 0,
    before_return: None,
  }
}

///|
pub impl @server.Listener for LifecycleListener with fn accept(self) {
  while self.pending.is_empty() && self.keep_open && !self.closed {
    self.waiting = true
    self.signal.wait()
  }
  self.waiting = false
  if self.closed {
    Ok(None)
  } else if !self.pending.is_empty() {
    let connection = self.pending.remove(0)
    if self.before_return is Some(callback) {
      callback()
    }
    Ok(Some(connection))
  } else if self.fail_accept {
    Err(AcceptFailed("test accept failed"))
  } else {
    Ok(None)
  }
}

///|
pub impl @server.Listener for LifecycleListener with fn close(self) {
  self.close_calls += 1
  self.closed = true
  self.signal.broadcast()
}

///|
async test "server supervisor: raised and returned peer errors preserve siblings and new connections" {
  @async.with_timeout(2000, async fn() {
    let supervisor = @server.ServerSupervisor::new().unwrap()
    let finish = @async.CondVar::Cond()
    let mut healthy_done = false
    let mut new_done = false
    let closes = [0, 0, 0, 0]
    let listener = LifecycleListener::new(
      [
        @server.AcceptedConnection::new(
          async fn() {
            finish.wait()
            healthy_done = true
            Ok(())
          },
          fn() { closes[0] += 1 },
        ),
        @server.AcceptedConnection::new(
          async fn() {
            @async.pause()
            raise @server.ServerError::HandlerFailed("raised error")
          },
          fn() { closes[1] += 1 },
        ),
        @server.AcceptedConnection::new(
          fn() { Err(@server.ServerError::HandlerFailed("returned error")) },
          fn() { closes[2] += 1 },
        ),
      ],
      keep_open=true,
    )
    @async.with_task_group(async fn(group) {
      let serving = group.spawn(async fn() { supervisor.serve(listener) })
      while supervisor.metrics().handler_errors() != 2L {
        @async.pause()
      }
      assert_eq(supervisor.state(), Running)
      assert_eq(supervisor.active_connections(), 1)
      listener.pending.push(
        @server.AcceptedConnection::new(
          fn() {
            new_done = true
            Ok(())
          },
          fn() { closes[3] += 1 },
        ),
      )
      listener.signal.broadcast()
      while !new_done {
        @async.pause()
      }
      finish.broadcast()
      supervisor.begin_shutdown().unwrap()
      assert_eq(serving.wait(), Ok(()))
    })
    assert_true(healthy_done && new_done)
    assert_eq(closes, [1, 1, 1, 1])
    assert_eq(listener.close_calls, 1)
    assert_eq(supervisor.active_connections(), 0)
    assert_eq(supervisor.metrics().completed(), 2L)
    assert_eq(supervisor.metrics().handler_errors(), 2L)
    assert_eq(supervisor.state(), Stopped)
  })
}

///|
async test "server supervisor: graceful deadline cancels peer and releases its slot once" {
  @async.with_timeout(2000, async fn() {
    let limits : @server.ServerLimits = {
      ..@server.ServerLimits::defaults(),
      graceful_timeout_ms: Some(10),
    }
    let supervisor = @server.ServerSupervisor::new(
      config=@server.ServerConfig::defaults().with_limits(limits),
    ).unwrap()
    let blocked = @async.CondVar::Cond()
    let mut closes = 0
    let mut finalized = false
    let listener = LifecycleListener::new([
      @server.AcceptedConnection::new(
        async fn() {
          defer {
            finalized = true
          }
          blocked.wait()
          Ok(())
        },
        fn() { closes += 1 },
      ),
    ])
    assert_eq(supervisor.serve(listener), Err(ShutdownTimeout))
    assert_true(finalized)
    assert_eq(closes, 1)
    assert_eq(listener.close_calls, 1)
    assert_eq(supervisor.active_connections(), 0)
    assert_eq(supervisor.metrics().completed(), 1L)
    assert_eq(supervisor.state(), Stopped)
  })
}

///|
async test "server supervisor: None grace waits for normal completion" {
  let limits : @server.ServerLimits = {
    ..@server.ServerLimits::defaults(),
    graceful_timeout_ms: None,
  }
  let supervisor = @server.ServerSupervisor::new(
    config=@server.ServerConfig::defaults().with_limits(limits),
  ).unwrap()
  let mut completed = false
  let listener = LifecycleListener::new([
    @server.AcceptedConnection::new(
      async fn() {
        @async.sleep(20)
        completed = true
        Ok(())
      },
      fn() { () },
    ),
  ])
  assert_eq(
    @async.with_timeout(2000, async fn() { supervisor.serve(listener) }),
    Ok(()),
  )
  assert_true(completed)
  assert_eq(supervisor.active_connections(), 0)
}

///|
async test "server supervisor: grace starts at shutdown rather than server startup" {
  @async.with_timeout(2000, async fn() {
    let limits : @server.ServerLimits = {
      ..@server.ServerLimits::defaults(),
      graceful_timeout_ms: Some(10),
    }
    let supervisor = @server.ServerSupervisor::new(
      config=@server.ServerConfig::defaults().with_limits(limits),
    ).unwrap()
    let finish = @async.CondVar::Cond()
    let mut entered = false
    let mut completed = false
    let listener = LifecycleListener::new(
      [
        @server.AcceptedConnection::new(
          async fn() {
            entered = true
            finish.wait()
            completed = true
            Ok(())
          },
          fn() { () },
        ),
      ],
      keep_open=true,
    )
    @async.with_task_group(async fn(group) {
      let serving = group.spawn(async fn() { supervisor.serve(listener) })
      while !entered {
        @async.pause()
      }
      @async.sleep(30)
      assert_eq(supervisor.state(), Running)
      assert_eq(supervisor.active_connections(), 1)
      finish.broadcast()
      supervisor.begin_shutdown().unwrap()
      assert_eq(serving.wait(), Ok(()))
    })
    assert_true(completed)
    assert_eq(supervisor.active_connections(), 0)
  })
}

///|
async test "server supervisor: beginning shutdown wakes an idle accept" {
  @async.with_timeout(2000, async fn() {
    let supervisor = @server.ServerSupervisor::new().unwrap()
    let listener = LifecycleListener::new([], keep_open=true)
    @async.with_task_group(async fn(group) {
      let serving = group.spawn(async fn() { supervisor.serve(listener) })
      while !listener.waiting {
        @async.pause()
      }
      supervisor.begin_shutdown().unwrap()
      supervisor.begin_shutdown().unwrap()
      assert_eq(serving.wait(), Ok(()))
    })
    assert_eq(listener.close_calls, 1)
    assert_eq(supervisor.state(), Stopped)
  })
}

///|
async test "server supervisor: external cancellation preserves cancellation and cleanup" {
  @async.with_timeout(2000, async fn() {
    let supervisor = @server.ServerSupervisor::new().unwrap()
    let blocked = @async.CondVar::Cond()
    let mut entered = false
    let mut closes = 0
    let listener = LifecycleListener::new(
      [
        @server.AcceptedConnection::new(
          async fn() {
            entered = true
            blocked.wait()
            Ok(())
          },
          fn() { closes += 1 },
        ),
      ],
      keep_open=true,
    )
    @async.with_task_group(async fn(group) {
      let serving = group.spawn(
        async fn() { supervisor.serve(listener) },
        allow_failure=true,
      )
      while !entered {
        @async.pause()
      }
      serving.cancel()
      try serving.wait() catch {
        @async.WaitedTaskAlreadyCancelled => ()
        error => raise error
      } noraise {
        _ => fail("supervisor swallowed cancellation")
      }
    })
    assert_eq(closes, 1)
    assert_eq(listener.close_calls, 1)
    assert_eq(supervisor.active_connections(), 0)
    assert_eq(supervisor.state(), Stopped)
  })
}

///|
async test "server supervisor: fatal accept errors cancel peers and retain the error" {
  @async.with_timeout(2000, async fn() {
    let limits : @server.ServerLimits = {
      ..@server.ServerLimits::defaults(),
      max_accept_errors: 1,
    }
    let supervisor = @server.ServerSupervisor::new(
      config=@server.ServerConfig::defaults().with_limits(limits),
    ).unwrap()
    let blocked = @async.CondVar::Cond()
    let mut closes = 0
    let listener = LifecycleListener::new(
      [
        @server.AcceptedConnection::new(
          async fn() {
            blocked.wait()
            Ok(())
          },
          fn() { closes += 1 },
        ),
      ],
      fail_accept=true,
    )
    assert_eq(supervisor.serve(listener), Err(AcceptErrorLimitExceeded))
    assert_eq(closes, 1)
    assert_eq(listener.close_calls, 1)
    assert_eq(supervisor.active_connections(), 0)
    assert_eq(supervisor.state(), Stopped)
  })
}

///|
async test "server supervisor: cancellation during accept handoff closes the unregistered peer" {
  @async.with_timeout(2000, async fn() {
    let supervisor = @server.ServerSupervisor::new().unwrap()
    let mut closes = 0
    let listener = LifecycleListener::new([], keep_open=true)
    @async.with_task_group(async fn(group) {
      let serving = group.spawn(
        async fn() { supervisor.serve(listener) },
        allow_failure=true,
      )
      while !listener.waiting {
        @async.pause()
      }
      listener.before_return = Some(fn() { serving.cancel() })
      listener.pending.push(
        @server.AcceptedConnection::new(fn() { Ok(()) }, fn() { closes += 1 }),
      )
      listener.signal.broadcast()
      try serving.wait() catch {
        @async.WaitedTaskAlreadyCancelled => ()
        error => raise error
      } noraise {
        _ => fail("supervisor swallowed cancellation during accept")
      }
    })
    assert_eq(closes, 1)
    assert_eq(listener.close_calls, 1)
    assert_eq(supervisor.metrics().accepted(), 0L)
    assert_eq(supervisor.active_connections(), 0)
    assert_eq(supervisor.state(), Stopped)
  })
}
