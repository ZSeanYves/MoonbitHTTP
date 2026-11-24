///|
test "http2 acknowledged zero window still permits empty END_STREAM" {
  let connection = @http2.H2Connection::new(Server)
  connection.set_local_initial_window(0).unwrap()
  connection
  .receive(test_frame(@http2.H2_FRAME_SETTINGS, @http2.H2_FLAGS_ACK, 0, []))
  .unwrap()
  |> ignore
  connection
  .receive(
    test_frame(@http2.H2_FRAME_HEADERS, @http2.H2_FLAGS_END_HEADERS, 1, []),
  )
  .unwrap()
  |> ignore
  connection
  .receive(test_frame(@http2.H2_FRAME_DATA, @http2.H2_FLAGS_END_STREAM, 1, []))
  .unwrap()
  |> ignore
  connection
  .receive(
    test_frame(@http2.H2_FRAME_HEADERS, @http2.H2_FLAGS_END_HEADERS, 3, []),
  )
  .unwrap()
  |> ignore
  assert_true(
    connection.receive(test_frame(@http2.H2_FRAME_DATA, 0, 3, [b'x']))
    is Err(StreamError(3, FlowControlError, _)),
  )
}
