///|
async test "content coding lifecycle: deflate and Brotli consume source EOF and preserve trailers" {
  let original = b"streaming resource lifetime"
  let cases = [
    (@content_coding.ContentCoding::Deflate, @zlib.zlib_compress(original)),
    (Brotli, Bytes::from_array(@fbr.brotli_sync(original.to_fixedarray()))),
  ]
  for entry in cases {
    let (coding, encoded) = entry
    for trailers in [false, true] {
      let mut cursor = 0
      let mut released = 0
      let mut cancelled = 0
      let source = @body.BodyStream::from_pull(
        fn() {
          cursor += 1
          if cursor == 1 {
            Some(Data(encoded))
          } else if trailers && cursor == 2 {
            let fields = @types.HeaderMap::new()
            fields.append_string("x-finished", "yes").unwrap()
            Some(Trailers(fields))
          } else {
            None
          }
        },
        on_terminate=fn(_) { released += 1 },
        on_cancel=fn(_) { cancelled += 1 },
      )
      let decoded = @content_coding.DecodedBody::new(source, [coding]).unwrap()
      let (bytes, fields) = @body.collect(decoded)
      assert_eq(bytes, original)
      assert_eq(fields is Some(_), trailers)
      assert_eq(released, 1)
      assert_eq(cancelled, 0)
      assert_eq(cursor, 2)
    }
  }
}

///|
async test "content coding lifecycle: encoded fragments after codec EOS cancel the source" {
  let original = b"payload"
  let cases = [
    (@content_coding.ContentCoding::Deflate, @zlib.zlib_compress(original)),
    (Brotli, Bytes::from_array(@fbr.brotli_sync(original.to_fixedarray()))),
  ]
  for entry in cases {
    let (coding, encoded) = entry
    let source : ContentTrackingBody = {
      frames: [Data(encoded), Data(b"trailing")],
      cursor: 0,
      cancel_count: 0,
    }
    let decoded = @content_coding.DecodedBody::new(source, [coding]).unwrap()
    try @body.collect(decoded) catch {
      @content_coding.ContentCodingError::TrailingEncodedData(actual) =>
        assert_eq(actual, coding)
      error => fail("unexpected trailing data error: \{error}")
    } noraise {
      _ => fail("trailing encoded body was accepted")
    }
    decoded.cancel(@body.BodyError::Cancelled)
    assert_eq(source.cancel_count, 1)
    assert_eq(source.cursor, 2)
  }
}

///|
async test "content coding lifecycle: inner EOS still validates an outer gzip trailer" {
  let encoded = @gzip.gzip_compress(@zlib.zlib_compress(b"nested"))
  let source : ContentTrackingBody = {
    frames: [Data(encoded[:encoded.length() - 8].to_owned())],
    cursor: 0,
    cancel_count: 0,
  }
  let decoded = @content_coding.DecodedBody::new(source, [Deflate, Gzip]).unwrap()
  try @body.collect(decoded) catch {
    @content_coding.ContentCodingError::TruncatedEncodedBody(Gzip) => ()
    error => fail("outer coding failure changed: \{error}")
  } noraise {
    _ => fail("inner EOS bypassed outer validation")
  }
  assert_eq(source.cancel_count, 1)
}

///|
async test "content coding lifecycle: cancelling a pull after codec EOS releases its source" {
  let compressed = @zlib.zlib_compress(b"payload")
  let waiting = @async.Semaphore::Semaphore(1, initial_value=0)
  let reached = @async.Semaphore::Semaphore(1, initial_value=0)
  let mut cursor = 0
  let mut cancelled = 0
  let source = @body.BodyStream::from_pull(
    async fn() {
      cursor += 1
      if cursor == 1 {
        Some(Data(compressed))
      } else {
        reached.release()
        waiting.acquire()
        None
      }
    },
    on_cancel=fn(_) { cancelled += 1 },
  )
  let decoded = @content_coding.DecodedBody::new(source, [Deflate]).unwrap()
  @async.with_task_group(async fn(group) {
    let consumer = group.spawn(
      async fn() { ignore(@body.collect(decoded)) },
      allow_failure=true,
    )
    reached.acquire()
    consumer.cancel()
    consumer.wait() catch {
      _ => ()
    }
  })
  assert_eq(cancelled, 1)
}
