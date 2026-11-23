///|
test "HTTP/2 coalesces connection and live stream credit independently of queued controls" {
  let connection = @http2.H2Connection::new(Client)
  let active = connection.open_local_stream().unwrap()
  let retired = connection.open_local_stream().unwrap()
  let control = H2ServerControl::new(connection, 2)
  for _ in 0..<32 {
    control.frame(b"ack")
  }
  for _ in 0..<64 {
    control.credit(SendWindowUpdate(0, 5))
    control.credit(SendWindowUpdate(active, 2))
    control.credit(SendWindowUpdate(retired, 3))
  }
  connection.reset_stream(retired).unwrap()
  for _ in 0..<32 {
    assert_eq(control.take(control.queue.try_get().unwrap()), b"ack")
  }
  let decoder = @http2.FrameDecoder::new()
  decoder.feed(control.take(control.queue.try_get().unwrap())).unwrap()
  let increments : Map[Int32, Int32] = Map([])
  while decoder.next().unwrap() is Some(frame) {
    assert_eq(frame.header.typ, @http2.H2_FRAME_WINDOW_UPDATE)
    let amount = frame.payload.fold(init=0, (n, b) => (n << 8) | b.to_int())
    increments[frame.header.stream_id] = amount
  }
  assert_eq(increments.length(), 2)
  assert_eq(increments.get(0), Some(320))
  assert_eq(increments.get(active), Some(128))
  assert_true(control.queue.try_get() is None)
  control.credit(SendWindowUpdate(active, 1))
  assert_eq(
    control.take(control.queue.try_get().unwrap()),
    @http2.encode_window_update(active, 1).unwrap(),
  )
}
