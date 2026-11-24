///|
fn discard_test_frame(
  typ : Int32,
  id : Int32,
  flags : Int32,
  bytes : Array[Byte],
) -> @http2.H2Frame {
  {
    header: { typ, stream_id: id, flags, length: bytes.length(), },
    payload: bytes,
  }
}

///|
test "h2 refused headers retain bounded continuation and compression actions" {
  let connection = @http2.H2Connection::new(Server, limits={
    ..@types.Limits::defaults(),
    max_concurrent_requests: 1,
    max_header_bytes: 8,
  })
  ignore(
    connection
    .receive(
      discard_test_frame(
        @http2.H2_FRAME_HEADERS,
        1,
        @http2.H2_FLAGS_END_HEADERS,
        [],
      ),
    )
    .unwrap(),
  )
  assert_true(
    connection.receive(
      discard_test_frame(@http2.H2_FRAME_HEADERS, 3, 0, [0x40]),
    )
    is Ok([HeadersDiscarded(3, false, RefusedStream)]),
  )
  assert_true(
    connection.receive(
      discard_test_frame(
        @http2.H2_FRAME_CONTINUATION,
        3,
        @http2.H2_FLAGS_END_HEADERS,
        [1, 120, 1, 118],
      ),
    )
    is Ok([HeadersContinued(3, true)]),
  )
  assert_true(
    connection.receive(
      discard_test_frame(@http2.H2_FRAME_HEADERS, 5, 0, [0x40]),
    )
    is Ok([HeadersDiscarded(5, false, RefusedStream)]),
  )
  assert_true(
    connection.receive(
      discard_test_frame(
        @http2.H2_FRAME_CONTINUATION,
        5,
        @http2.H2_FLAGS_END_HEADERS,
        [0, 0, 0, 0, 0, 0, 0, 0],
      ),
    )
    is Err(ConnectionError(EnhanceYourCalm, _)),
  )
}

///|
test "h2 closed headers require decode and prohibit interleaved continuation" {
  let connection = @http2.H2Connection::new(Server)
  ignore(
    connection
    .receive(
      discard_test_frame(
        @http2.H2_FRAME_HEADERS,
        1,
        @http2.H2_FLAGS_END_HEADERS | @http2.H2_FLAGS_END_STREAM,
        [],
      ),
    )
    .unwrap(),
  )
  assert_true(
    connection.receive(
      discard_test_frame(@http2.H2_FRAME_HEADERS, 1, 0, [0x40]),
    )
    is Ok([HeadersDiscarded(1, false, StreamClosed)]),
  )
  assert_true(
    connection.receive(
      discard_test_frame(
        @http2.H2_FRAME_HEADERS,
        3,
        @http2.H2_FLAGS_END_HEADERS,
        [],
      ),
    )
    is Err(ConnectionError(ProtocolError, _)),
  )
}
