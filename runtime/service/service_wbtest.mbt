///|
async test "service timeout helpers preserve bytes and default policy" {
  let defaults = ServerConfig::defaults()
  assert_eq(defaults.read_timeout_ms, Some(30000))
  assert_eq(defaults.write_timeout_ms, Some(30000))
  assert_eq(defaults.validate(), Ok(()))
  let reader = @aio.MemoryReader(async fn(writer) { writer.write(b"ok") })
  assert_eq(read_some_with_timeout(reader, 16, Some(100)), Some(b"ok"))
  let (written, writer) = @aio.memory_pipe()
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() { write_with_timeout(writer, b"ok", Some(100)) })
    assert_eq(written.read_exactly(2), b"ok")
  })
}

///|
#derive(Debug)
priv suberror LifecycleTestError

///|
async test "HTTP/2 writers enforce the declared length before DATA, trailers and completion" {
  let headers = @types.HeaderMap::new()
  headers.append_string("content-length", "2").unwrap()
  try ignore(h2_outgoing_length(1, headers, Some(3))) catch {
    StreamError(1, ProtocolError, _) => ()
    error => raise error
  } noraise {
    _ => fail("accepted a known length mismatch")
  }
  let expected = h2_outgoing_length(1, headers, None)
  let trailers = @types.HeaderMap::new()
  for
    (frames, payload_frames) in [
      ([@body.Frame::Data(b"abc")], 0),
      ([Data(b"a")], 1),
      ([Data(b"a"), Trailers(trailers)], 1),
    ] {
    let mut writes = 0
    let body = @body.QueueBody::new(frames)
    try
      write_h2_body(
        1,
        () => body.next_frame(),
        expected,
        false,
        chunk => {
          writes += 1
          chunk.length()
        },
        _ => writes += 1,
        _ => fail("sent premature trailers"),
      )
    catch {
      @http2.H2ProtocolError::StreamError(1, ProtocolError, _) => ()
      error => raise error
    } noraise {
      _ => fail("accepted a mismatched streaming body")
    }
    assert_eq(writes, payload_frames)
  }
}

///|
async test "service connection scope reports success and error once" {
  let events : Array[String] = []
  let value = run_connection_scope(
    () => 42,
    Some(fn(error) { events.push(if error is None { "ok" } else { "error" }) }),
  )
  assert_eq(value, 42)
  try {
    let _ : Unit = run_connection_scope(
      () => raise LifecycleTestError,
      Some(fn(error) { events.push(if error is None { "ok" } else { "error" }) }),
    )
  } catch {
    LifecycleTestError => ()
    _ => fail("connection scope changed the operation error")
  } noraise {
    _ => fail("connection scope swallowed the operation error")
  }
  assert_eq(events, ["ok", "error"])
}

///|
async test "service connection scope reports asynchronous cancellation" {
  let events : Array[String] = []
  @async.with_task_group(async fn(group) {
    let started : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
    let task = group.spawn(() => {
      run_connection_scope(
        () => {
          started.put(())
          @async.sleep(60_000)
        },
        Some(fn(error) {
          events.push(if error is None { "ok" } else { "cancelled" })
        }),
      )
    })
    started.get()
    task.cancel()
    try task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      _ => fail("cancelled connection scope changed its terminal state")
    } noraise {
      _ => fail("cancelled connection scope completed normally")
    }
  })
  assert_eq(events, ["cancelled"])
}
