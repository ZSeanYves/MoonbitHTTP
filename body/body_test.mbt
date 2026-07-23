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
