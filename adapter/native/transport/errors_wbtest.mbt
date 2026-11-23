///|
async test "native TCP: refused connections preserve errno with and without a deadline" {
  let reservation = @socket.TcpServer(Addr(@socket.IpAddr::v4(0x7f000001U), 0))
  let endpoint = @types.Endpoint::new(
    "tcp",
    "127.0.0.1",
    reservation.addr.port.to_int(),
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
          @os_error.from_errno(code, context="connect")
          is OsError(ConnectionRefused, ..),
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
  let listener = @socket.TcpServer(Addr(@socket.IpAddr::v4(0x7f000001U), 0))
  defer listener.close()
  let endpoint = @types.Endpoint::new(
    "tcp",
    "127.0.0.1",
    listener.addr.port.to_int(),
  ).unwrap()
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
    let listener = @socket.TcpServer(Addr(@socket.IpAddr::v4(0x7f000001U), 0))
    defer listener.close()
    let endpoint = @types.Endpoint::new(
      "tcp",
      "127.0.0.1",
      listener.addr.port.to_int(),
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
        try task.wait() catch {
          @async.WaitedTaskAlreadyCancelled => ()
          _ => fail("caller cancellation changed its task result")
        } noraise {
          _ => fail("cancelled TCP read completed normally")
        }
      })
    })
    assert_eq(observed.val, None)
    assert_true(connection.is_closed())
  }
}

///|
test "native resolver preserves system order and bounds unique same-family results" {
  let candidates = [b"127.0.0.2", b"127.0.0.2", b"127.0.0.1", b"::1"]
  let mut index = 0
  let addresses = collect_addresses(2, fn() {
    let bytes = candidates[index]
    index += 1
    bytes
  }).unwrap()
  assert_eq(addresses.map(address => address.value()), [
    "127.0.0.2", "127.0.0.1",
  ])
  assert_eq(index, 3)
}
