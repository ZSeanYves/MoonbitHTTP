///|
fn window_test_frame(
  typ : Int,
  flags : Int,
  stream_id : Int,
  payload : Array[Byte],
) -> H2Frame {
  { header: { typ, flags, stream_id, length: payload.length(), }, payload, }
}

///|
test "http2 local SETTINGS decrease takes effect only after ACK and restores consumed credit" {
  let connection = H2Connection::new(Server)
  connection.set_local_initial_window(9).unwrap()
  connection
  .receive(window_test_frame(H2_FRAME_HEADERS, H2_FLAGS_END_HEADERS, 1, []))
  .unwrap()
  |> ignore
  connection
  .receive(window_test_frame(H2_FRAME_DATA, 0, 1, Array::make(64, b'x')))
  .unwrap()
  |> ignore
  assert_eq(connection.streams[1].recv_window, 65535 - 64)
  connection
  .receive(window_test_frame(H2_FRAME_SETTINGS, H2_FLAGS_ACK, 0, []))
  .unwrap()
  |> ignore
  assert_eq(connection.streams[1].recv_window, -55)
  connection.release_capacity(1, 64).unwrap() |> ignore
  assert_eq(connection.streams[1].recv_window, 9)
  connection
  .receive(window_test_frame(H2_FRAME_DATA, 0, 1, Array::make(9, b'x')))
  .unwrap()
  |> ignore
  assert_true(
    connection.receive(window_test_frame(H2_FRAME_DATA, 0, 1, [b'x']))
    is Err(StreamError(1, FlowControlError, _)),
  )
}

///|
test "http2 acknowledged zero window still permits empty END_STREAM" {
  let connection = H2Connection::new(Server)
  connection.set_local_initial_window(0).unwrap()
  connection
  .receive(window_test_frame(H2_FRAME_SETTINGS, H2_FLAGS_ACK, 0, []))
  .unwrap()
  |> ignore
  connection
  .receive(window_test_frame(H2_FRAME_HEADERS, H2_FLAGS_END_HEADERS, 1, []))
  .unwrap()
  |> ignore
  connection
  .receive(window_test_frame(H2_FRAME_DATA, H2_FLAGS_END_STREAM, 1, []))
  .unwrap()
  |> ignore
  connection
  .receive(window_test_frame(H2_FRAME_HEADERS, H2_FLAGS_END_HEADERS, 3, []))
  .unwrap()
  |> ignore
  assert_true(
    connection.receive(window_test_frame(H2_FRAME_DATA, 0, 3, [b'x']))
    is Err(StreamError(3, FlowControlError, _)),
  )
}

///|
test "http2 local SETTINGS acknowledgements preserve advertised order" {
  let connection = H2Connection::new(Server)
  connection.set_local_initial_window(9).unwrap()
  connection.set_local_initial_window(32).unwrap()
  connection
  .receive(window_test_frame(H2_FRAME_HEADERS, H2_FLAGS_END_HEADERS, 1, []))
  .unwrap()
  |> ignore
  connection
  .receive(window_test_frame(H2_FRAME_DATA, 0, 1, Array::make(10, b'x')))
  .unwrap()
  |> ignore
  connection
  .receive(window_test_frame(H2_FRAME_SETTINGS, H2_FLAGS_ACK, 0, []))
  .unwrap()
  |> ignore
  assert_eq(connection.streams[1].recv_window, -1)
  connection
  .receive(window_test_frame(H2_FRAME_SETTINGS, H2_FLAGS_ACK, 0, []))
  .unwrap()
  |> ignore
  assert_eq(connection.streams[1].recv_window, 22)
}
