///|
struct TimeoutCaptureWriter {
  bytes : Array[Byte]
}

///|
impl @aio.Writer for TimeoutCaptureWriter with fn write_once(
  self,
  data,
  offset~,
  len~,
) {
  for i in offset..<(offset + len) {
    self.bytes.push(data[i])
  }
  len
}

///|
async test "service timeout helpers preserve bytes and default policy" {
  let defaults = ServerConfig::defaults()
  assert_eq(defaults.read_timeout_ms, Some(30000))
  assert_eq(defaults.write_timeout_ms, Some(30000))
  assert_eq(defaults.validate(), Ok(()))
  let reader = @aio.MemoryReader(async fn(writer) { writer.write(b"ok") })
  assert_eq(read_some_with_timeout(reader, 16, Some(100)), Some(b"ok"))
  let writer : TimeoutCaptureWriter = { bytes: [], }
  write_with_timeout(writer, b"ok", Some(100))
  assert_eq(Bytes::from_array(writer.bytes), b"ok")
}

///|
priv suberror LifecycleTestError derive(Debug)

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
      error => assert_true(@async.is_cancellation_error(error))
    } noraise {
      _ => fail("cancelled connection scope completed normally")
    }
  })
  assert_eq(events, ["cancelled"])
}
