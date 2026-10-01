///|
test "HTTP/1 body encoder rejects invalid length without consuming state" {
  let encoder = @http1.BodyEncoder::new(ContentLength(3)).unwrap()
  assert_true(encoder.data(b"overlong") is Err(InvalidFraming(_)))
  assert_eq(encoder.data(b"ab"), Ok(b"ab"))
  assert_true(encoder.finish() is Err(InvalidFraming(_)))
  assert_true(
    encoder.trailers(@types.HeaderMap::new()) is Err(InvalidFraming(_)),
  )
  assert_eq(encoder.data(b"c"), Ok(b"c"))
  assert_eq(encoder.finish(), Ok(b""))
  assert_true(encoder.data(b"d") is Err(InvalidFraming(_)))
}

///|
test "HTTP/1 body encoder permits exactly one terminal trailer block" {
  let encoder = @http1.BodyEncoder::new(Chunked).unwrap()
  assert_eq(encoder.data(b"abc"), Ok(b"3\r\nabc\r\n"))
  let trailers = @types.HeaderMap::new()
  trailers.append_string("x-end", "yes").unwrap()
  assert_eq(encoder.trailers(trailers), Ok(b"0\r\nx-end: yes\r\n\r\n"))
  assert_true(encoder.data(b"late") is Err(InvalidFraming(_)))
  assert_true(encoder.trailers(trailers) is Err(InvalidFraming(_)))
  assert_eq(encoder.finish(), Ok(b""))
}
