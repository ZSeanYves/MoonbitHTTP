///|
test "h2 rejected DATA consumes and restores connection credit exactly once" {
  let connection = H2Connection::new(Server)
  connection.set_local_initial_window(1).unwrap()
  connection
  .receive(window_test_frame(H2_FRAME_SETTINGS, H2_FLAGS_ACK, 0, []))
  .unwrap()
  |> ignore
  connection
  .receive(window_test_frame(H2_FRAME_HEADERS, H2_FLAGS_END_HEADERS, 1, []))
  .unwrap()
  |> ignore
  assert_true(
    connection.receive(window_test_frame(H2_FRAME_DATA, 0, 1, [b'a', b'b']))
    is Err(StreamError(1, FlowControlError, _)),
  )
  assert_eq(connection.connection_recv_window, 65533)
  assert_true(
    connection.release_discarded_capacity().unwrap() is [SendWindowUpdate(0, 2)],
  )
  assert_eq(connection.connection_recv_window, 65535)
  assert_true(connection.release_discarded_capacity().unwrap().is_empty())
  // DATA that was already in flight when a stream reset must count as well.
  assert_true(
    connection.receive(window_test_frame(H2_FRAME_DATA, 0, 1, [b'c']))
    is Err(StreamError(1, StreamClosed, _)),
  )
  assert_eq(connection.connection_recv_window, 65534)
  assert_true(
    connection.release_discarded_capacity().unwrap() is [SendWindowUpdate(0, 1)],
  )
  assert_eq(connection.connection_recv_window, 65535)
}
