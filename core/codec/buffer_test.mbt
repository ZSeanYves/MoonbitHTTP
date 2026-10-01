///|
test "codec: fragmented line and preserved remainder" {
  let buffer = @codec.Buffer::new()
  assert_eq(buffer.feed(b"hello\r"), Ok(()))
  assert_eq(buffer.read_line(32), Err(NeedMore))
  assert_eq(buffer.feed(b"\nnext"), Ok(()))
  assert_eq(buffer.read_line(32).unwrap(), b"hello")
  assert_eq(buffer.peek(), b"next")
}

///|
test "codec: consumed prefix does not change relative line offsets" {
  let buffer = @codec.Buffer::new()
  assert_eq(buffer.feed(b"discard\r\nnext\r\n"), Ok(()))
  assert_eq(buffer.take(9), b"discard\r\n")
  assert_eq(buffer.read_line(32).unwrap(), b"next")
  assert_eq(buffer.peek(), b"")
}

///|
test "codec: buffer limits are checked before accumulation" {
  let buffer = @codec.Buffer::new(max_bytes=3)
  assert_eq(buffer.feed(b"ab"), Ok(()))
  assert_true(buffer.feed(b"cd") is Err(LimitExceeded(limit=3, ..)))
  assert_eq(buffer.peek(), b"ab")
  let invalid = @codec.Buffer::new(max_bytes=-1)
  assert_true(invalid.feed(b"") is Err(LimitExceeded(limit=-1, ..)))
}
