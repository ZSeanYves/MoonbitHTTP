///|
async test "body: queue exposes data and trailers" {
  let trailers = @types.HeaderMap::new()
  assert_eq(trailers.append_string("x-checksum", "ok"), Ok(()))
  let body = QueueBody::new([Data(b"ab"), Data(b"cd"), Trailers(trailers)])
  let (bytes, got_trailers) = collect(body)
  assert_eq(bytes, b"abcd")
  assert_eq(
    got_trailers.unwrap().get_string("x-checksum").unwrap().to_string_lossy(),
    "ok",
  )
}

///|
async test "body: bounded stream preserves frames and terminal errors" {
  let stream = BodyStream::new(capacity=1)
  stream.push(Data(b"first"))
  match stream.next_frame() {
    Some(Data(data)) => assert_eq(data, b"first")
    _ => fail("missing first frame")
  }
  stream.push(Data(b"second"))
  stream.finish()
  match stream.next_frame() {
    Some(Data(data)) => assert_eq(data, b"second")
    _ => fail("missing second frame")
  }
  assert_true(stream.next_frame() is None)
  let failed = BodyStream::new(capacity=1)
  failed.fail(@types.UriError::InvalidUri("body failed"))
  try failed.next_frame() catch {
    _ => ()
  } noraise {
    _ => fail("body stream failure was swallowed")
  }
}

///|
async test "body: blocked producer resumes after consumption" {
  let stream = BodyStream::new(capacity=1)
  let first_written : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
  let second_written : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() {
      stream.push(Data(b"one"))
      first_written.put(())
      stream.push(Data(b"two"))
      second_written.put(())
      stream.finish()
    })
    first_written.get()
    assert_eq(second_written.try_get(), None)
    assert_eq(stream.next_frame() is Some(Data(b"one")), true)
    second_written.get()
    assert_eq(stream.next_frame() is Some(Data(b"two")), true)
    guard stream.next_frame() is None else { fail("stream did not finish") }
  })
}

///|
async test "body: fail wakes blocked producer with original error" {
  let stream = BodyStream::new(capacity=1)
  stream.push(Data(b"buffered"))
  let failed : @aqueue.Queue[Bool] = Queue(kind=Unbounded)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() {
      stream.push(Data(b"blocked")) catch {
        @types.UriError::InvalidUri("cancelled") => {
          failed.put(true)
          return
        }
        _ => ()
      }
      failed.put(false)
    })
    @async.pause()
    stream.fail(@types.UriError::InvalidUri("cancelled"))
    assert_eq(failed.get(), true)
    assert_eq(stream.next_frame() is Some(Data(b"buffered")), true)
    try stream.next_frame() catch {
      @types.UriError::InvalidUri("cancelled") => ()
      _ => fail("BodyStream changed the terminal error")
    } noraise {
      _ => fail("BodyStream swallowed the terminal error")
    }
  })
}

///|
async test "body: pull stream can be failed externally" {
  let mut pulls = 0
  let stream = BodyStream::from_pull(async fn() {
    @async.pause()
    pulls += 1
    Some(Data(b"unexpected"))
  })
  stream.fail(@types.UriError::InvalidUri("pull cancelled"))
  try stream.next_frame() catch {
    @types.UriError::InvalidUri("pull cancelled") => ()
    _ => fail("pull stream changed the terminal error")
  } noraise {
    _ => fail("pull stream ignored external failure")
  }
  assert_eq(pulls, 0)
}

///|
async test "body: consumption callback failure terminates the stream" {
  let stream = BodyStream::new(capacity=1, on_data_consumed=fn(_) raise {
    raise @types.UriError::InvalidUri("window update failed")
  })
  stream.push(Data(b"data"))
  try stream.next_frame() catch {
    @types.UriError::InvalidUri("window update failed") => ()
    _ => fail("consumption callback error changed")
  } noraise {
    _ => fail("consumption callback error was swallowed")
  }
  try stream.push(Data(b"late")) catch {
    @types.UriError::InvalidUri("window update failed") => ()
    _ => fail("terminated stream did not preserve callback error")
  } noraise {
    _ => fail("terminated stream accepted a frame")
  }
}
