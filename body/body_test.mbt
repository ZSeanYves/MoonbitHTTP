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
