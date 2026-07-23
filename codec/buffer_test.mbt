///|
test "codec: fragmented line and preserved remainder" {
  let buffer = Buffer::new()
  assert_eq(buffer.feed(b"hello\r"), Ok(()))
  assert_eq(buffer.read_line(32), Err(NeedMore))
  assert_eq(buffer.feed(b"\nnext"), Ok(()))
  assert_eq(buffer.read_line(32).unwrap(), b"hello")
  assert_eq(buffer.peek(), b"next")
}
