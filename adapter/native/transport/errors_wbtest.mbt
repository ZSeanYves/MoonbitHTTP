///|
async test "native TCP: refused connections preserve errno with and without a deadline" {
  let reservation = @socket.TcpServer(@socket.Addr::new(0x7f000001U, 0))
  let endpoint = @types.Endpoint::new(
    "tcp",
    "127.0.0.1",
    reservation.addr.port(),
  ).unwrap()
  reservation.close()
  for timeout_ms in [Some(5000), None] {
    let result = TcpConnector::new().connect(endpoint, {
      ..@transport_api.ConnectOptions::defaults(),
      timeout_ms,
    })
    match result {
      Err(SystemFailure(Connect, code, message)) => {
        assert_true(
          @os_error.OSError(code, context="regression test").is_ECONNREFUSED(),
        )
        assert_false(message.is_empty())
      }
      Err(error) => fail("connection refusal was misclassified: \{Repr(error)}")
      Ok(connection) => {
        connection.close()
        fail("closed listener unexpectedly accepted a connection")
      }
    }
  }
}

///|
async test "native TCP: an actual idle deadline is a receive timeout and closes the stream" {
  let listener = @socket.TcpServer(@socket.Addr::new(0x7f000001U, 0))
  defer listener.close()
  let endpoint = @types.Endpoint::new("tcp", "127.0.0.1", listener.addr.port()).unwrap()
  let connection = TcpConnector::new()
    .connect(endpoint, {
      ..@transport_api.ConnectOptions::defaults(),
      idle_timeout_ms: Some(20),
    })
    .unwrap()
  defer connection.close()
  let (peer, _) = listener.accept()
  defer peer.close()
  assert_eq(connection.read(1), Err(Timeout(Receive)))
  assert_true(connection.is_closed())
}

///|
async test "native TCP: caller cancellation remains distinct from an idle timeout" {
  for idle_timeout_ms in [None, Some(10000)] {
    let listener = @socket.TcpServer(@socket.Addr::new(0x7f000001U, 0))
    defer listener.close()
    let endpoint = @types.Endpoint::new(
      "tcp",
      "127.0.0.1",
      listener.addr.port(),
    ).unwrap()
    let connection = TcpConnector::new()
      .connect(endpoint, {
        ..@transport_api.ConnectOptions::defaults(),
        idle_timeout_ms,
      })
      .unwrap()
    defer connection.close()
    let (peer, _) = listener.accept()
    defer peer.close()
    let observed : Ref[Result[Bytes?, @transport_api.TransportError]?] = Ref(
      None,
    )
    @async.with_timeout(5000, async fn() {
      @async.with_task_group(async fn(group) {
        let task = group.spawn(async fn() {
          observed.val = Some(connection.read(1))
        })
        @async.sleep(5)
        task.cancel()
      })
    })
    assert_eq(observed.val, Some(Err(Cancelled)))
    assert_true(connection.is_closed())
  }
}

///|
async test "native resolver: family fallback preserves causes and stops on cancellation" {
  let ipv6 = @types.IpAddress::parse("::1").unwrap()
  let mut lookups = 0
  let resolved = resolve_native_host("v6.example", 2, lookup=fn(_, protocol) {
    lookups += 1
    match protocol {
      OnlyV4 => Err(Failed(Resolve, "no IPv4 address"))
      _ => Ok(ipv6)
    }
  }).unwrap()
  assert_eq(resolved, [ipv6])
  assert_eq(lookups, 2)
  let original : @transport_api.TransportError = SystemFailure(
    Resolve,
    13,
    "resolver access denied",
  )
  assert_eq(
    resolve_native_host("blocked.example", 2, lookup=fn(_, _) { Err(original) }),
    Err(original),
  )
  for failure in [@transport_api.TransportError::Cancelled, Timeout(Resolve)] {
    lookups = 0
    assert_eq(
      resolve_native_host("cancelled.example", 2, lookup=fn(_, _) {
        lookups += 1
        Err(failure)
      }),
      Err(failure),
    )
    assert_eq(lookups, 1)
  }
  lookups = 0
  assert_eq(
    resolve_native_host("bounded.example", 1, lookup=fn(_, _) {
      lookups += 1
      Ok(ipv6)
    }),
    Ok([ipv6]),
  )
  assert_eq(lookups, 1)
}
