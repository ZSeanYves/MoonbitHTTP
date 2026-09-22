///|
async test "body: queue exposes data and trailers" {
  let trailers = @types.HeaderMap::new()
  assert_eq(trailers.append_string("x-checksum", "ok"), Ok(()))
  let body = @body.QueueBody::new([Data(b"ab"), Data(b"cd"), Trailers(trailers)])
  let (bytes, got_trailers) = @body.collect(body)
  assert_eq(bytes, b"abcd")
  assert_eq(
    got_trailers.unwrap().get_string("x-checksum").unwrap().to_string_lossy(),
    "ok",
  )
}

///|
async test "body: bounded stream preserves frames and terminal errors" {
  let stream = @body.BodyStream::new(capacity=1)
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
  let failed = @body.BodyStream::new(capacity=1)
  failed.fail(@types.UriError::InvalidUri("body failed"))
  try failed.next_frame() catch {
    _ => ()
  } noraise {
    _ => fail("body stream failure was swallowed")
  }
}

///|
async test "body: blocked producer resumes after consumption" {
  let stream = @body.BodyStream::new(capacity=1)
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
async test "body: repeated consumption keeps wakeup state bounded" {
  let stream = @body.BodyStream::new(capacity=1)
  for _ in 0..<10000 {
    stream.push(Data(b"x"))
    match stream.next_frame() {
      Some(Data(data)) => assert_eq(data, b"x")
      _ => fail("body stream lost a repeated frame")
    }
  }
  stream.finish()
  assert_true(stream.next_frame() is None)
}

///|
async test "body: fail wakes blocked producer with original error" {
  let stream = @body.BodyStream::new(capacity=1)
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
      _ => fail("@body.BodyStream changed the terminal error")
    } noraise {
      _ => fail("@body.BodyStream swallowed the terminal error")
    }
  })
}

///|
async test "body: pull stream can be failed externally" {
  let mut pulls = 0
  let stream = @body.BodyStream::from_pull(async fn() {
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
  let stream = @body.BodyStream::new(capacity=1, on_data_consumed=fn(_) raise {
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

///|
async test "body: empty data is normalized without hiding later data" {
  let full = @body.FullBody::new(b"")
  assert_true(full.next_frame() is None)
  let queued = @body.QueueBody::new([Data(b""), Data(b"payload"), Data(b"")])
  let (data, trailers) = @body.collect(queued)
  assert_eq(data, b"payload")
  assert_true(trailers is None)
  let mut pulls = 0
  let pulled = @body.BodyStream::from_pull(() => {
    pulls += 1
    match pulls {
      1 => Some(Data(b""))
      2 => Some(Data(b"payload"))
      _ => None
    }
  })
  guard pulled.next_frame() is Some(Data(data)) else {
    fail("pull stream did not expose the non-empty frame")
  }
  assert_eq(data, b"payload")
  assert_true(pulled.next_frame() is None)
}

///|
async test "body: trailers are terminal for push streams" {
  let stream = @body.BodyStream::new(capacity=2)
  let trailers = @types.HeaderMap::new()
  stream.push(Trailers(trailers))
  try stream.push(Data(b"late")) catch {
    @body.BodyError::DataAfterTrailers => ()
    _ => fail("data-after-trailers error changed")
  } noraise {
    _ => fail("body stream accepted data after trailers")
  }
  try stream.try_push(Trailers(@types.HeaderMap::new())) catch {
    @body.BodyError::DuplicateTrailers => ()
    _ => fail("duplicate-trailers error changed")
  } noraise {
    _ => fail("body stream accepted duplicate trailers")
  }
  assert_true(stream.next_frame() is Some(Trailers(_)))
  assert_true(stream.next_frame() is None)
}

///|
async test "body: collect rejects invalid frame sequences" {
  let data_after = @body.QueueBody::new([
    Trailers(@types.HeaderMap::new()),
    Data(b"late"),
  ])
  try @body.collect(data_after) catch {
    @body.BodyError::DataAfterTrailers => ()
    _ => fail("collect changed the data-after-trailers error")
  } noraise {
    _ => fail("collect accepted data after trailers")
  }
  let duplicate = @body.QueueBody::new([
    Trailers(@types.HeaderMap::new()),
    Trailers(@types.HeaderMap::new()),
  ])
  try @body.collect(duplicate) catch {
    @body.BodyError::DuplicateTrailers => ()
    _ => fail("collect changed the duplicate-trailers error")
  } noraise {
    _ => fail("collect accepted duplicate trailers")
  }
}

///|
async test "body: collect limit cancels and clears upstream" {
  let stream = @body.BodyStream::new(capacity=2)
  stream.push(Data(b"buffered"))
  stream.push(Data(b"discarded"))
  try @body.collect(stream, max_bytes=3) catch {
    @body.BodyLimitExceeded::@body.BodyLimitExceeded(limit=3) => ()
    _ => fail("collect changed the body limit error")
  } noraise {
    _ => fail("collect accepted an oversized body")
  }
  try stream.next_frame() catch {
    @body.BodyLimitExceeded::@body.BodyLimitExceeded(limit=3) => ()
    _ => fail("cancelled stream changed the body limit error")
  } noraise {
    _ => fail("cancelled stream retained buffered frames")
  }
}

///|
async test "body: cancelling a blocked producer terminates the stream" {
  let stream = @body.BodyStream::new(capacity=1)
  stream.push(Data(b"buffered"))
  @async.with_task_group(async fn(group) {
    let started : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
    let producer = group.spawn(async fn() {
      started.put(())
      stream.push(Data(b"blocked"))
    })
    started.get()
    @async.pause()
    producer.cancel()
    try producer.wait() catch {
      error => assert_true(@async.is_cancellation_error(error))
    } noraise {
      _ => fail("cancelled producer completed normally")
    }
    try stream.next_frame() catch {
      @body.BodyError::Cancelled => ()
      _ => fail("producer cancellation changed the stream error")
    } noraise {
      _ => fail("producer cancellation did not clear buffered data")
    }
  })
}

///|
async test "body: termination callback runs exactly once with the first cause" {
  let causes : Array[String] = []
  let completed = @body.BodyStream::from_pull(fn() { None }, on_terminate=fn(
    error,
  ) {
    causes.push(if error is None { "eof" } else { "error" })
  })
  assert_true(completed.next_frame() is None)
  completed.finish()
  completed.cancel(@body.BodyError::Cancelled)
  assert_eq(causes, ["eof"])
  let cancelled = @body.BodyStream::new(on_terminate=fn(error) {
    causes.push(if error is Some(_) { "cancelled" } else { "eof" })
  })
  cancelled.cancel(@body.BodyError::Cancelled)
  cancelled.cancel(@types.UriError::InvalidUri("later"))
  assert_eq(causes, ["eof", "cancelled"])
}
