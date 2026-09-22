///|
fn security_test_frame(
  typ : Int,
  stream_id : Int,
  payload : Array[Byte],
) -> H2Frame {
  { header: { length: payload.length(), typ, flags: 0, stream_id, }, payload, }
}

///|
test "h2 runtime: window and stream-id arithmetic cannot wrap" {
  let receive = H2Connection::new(Server)
  receive.connection_recv_window = 0x7fffffff
  assert_true(
    receive.increase_connection_receive_window(1)
    is Err(ConnectionError(FlowControlError, _)),
  )
  let send = H2Connection::new(Client)
  send.connection_send_window = 0x7fffffff
  assert_true(
    send.receive(security_test_frame(H2_FRAME_WINDOW_UPDATE, 0, [0, 0, 0, 1]))
    is Err(ConnectionError(FlowControlError, _)),
  )
  let exhausted = H2Connection::new(Client)
  exhausted.next_local_stream = 0x7fffffff
  assert_eq(exhausted.open_local_stream().unwrap(), 0x7fffffff)
  assert_true(
    exhausted.open_local_stream() is Err(ConnectionError(RefusedStream, _)),
  )
}
