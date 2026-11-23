///|
fn driver_request_fields() -> Array[@http3.QpackField] {
  [
    qpack_test_field(":method", "GET"),
    qpack_test_field(":scheme", "https"),
    qpack_test_field(":authority", "example.com"),
    qpack_test_field(":path", "/"),
  ]
}

///|
test "http3 driver: fragmented control and request streams" {
  let driver = @http3.Http3Driver::new(H3Server).unwrap()
  let settings = @http3.encode_http3_frame(H3SettingsFrame([])).unwrap()
  let control_prefix = Bytes::from_array([0, settings[0]])
  ignore(driver.on_stream_data(2L, control_prefix, false).unwrap())
  ignore(driver.on_stream_data(2L, settings[1:].to_owned(), false).unwrap())
  let header_section = @http3.qpack_encode_static(driver_request_fields()).unwrap()
  let request_frame = @http3.encode_http3_frame(H3Headers(header_section)).unwrap()
  let first = request_frame[:2].to_owned()
  ignore(driver.on_stream_data(0L, first, false).unwrap())
  let actions = driver
    .on_stream_data(0L, request_frame[2:].to_owned(), true)
    .unwrap()
  assert_true(
    actions.any(fn(action) {
      action is Event(H3HeadersReceived(0L, _, false, false))
    }),
  )
}

///|
test "http3 driver: a peer can finish before identifying a unidirectional stream" {
  let driver = @http3.Http3Driver::new(H3Server).unwrap()
  assert_eq(driver.on_stream_data(2L, b"", true), Ok([]))
  assert_eq(driver.on_stream_data(6L, b"\x40", false), Ok([]))
  assert_eq(driver.on_stream_data(6L, b"", true), Ok([]))
  assert_eq(driver.on_stream_reset(6L), Ok([]))
  assert_eq(driver.on_stop_sending(0L), Ok([]))
  assert_eq(driver.failure(), None)
  assert_true(
    driver.on_stream_data(10L, b"\x00", true)
    is Err(Http3ConnectionError(H3ClosedCriticalStream, _)),
  )
}

///|
test "http3 driver: critical streams and cancellation produce QUIC actions" {
  let driver = @http3.Http3Driver::new(H3Client).unwrap()
  let initial = driver.initial_stream_actions().unwrap()
  assert_eq(initial.length(), 3)
  assert_true(initial[0] is SendOnStream(2L, _, false))
  assert_true(initial[1] is SendOnStream(6L, b"\x02", false))
  assert_true(initial[2] is SendOnStream(10L, b"\x03", false))
  let stream_id = driver
    .open_request_stream(request_method=Some("GET"))
    .unwrap()
  let cancelled = driver.cancel_request_stream(stream_id).unwrap()
  assert_true(
    driver.on_stop_sending(6L)
    is Err(Http3ConnectionError(H3ClosedCriticalStream, _)),
  )
  assert_true(
    cancelled
    is [
      ResetStream(0L, H3RequestCancelled),
      StopSending(0L, H3RequestCancelled),
      SendOnStream(10L, _, false),
    ],
  )
}

///|
test "http3 driver: request can complete before the peer control stream arrives" {
  let driver = @http3.Http3Driver::new(H3Server).unwrap()
  let header_section = @http3.qpack_encode_static(driver_request_fields()).unwrap()
  let request_frame = @http3.encode_http3_frame(H3Headers(header_section)).unwrap()
  let actions = driver.on_stream_data(0L, request_frame, true).unwrap()
  assert_true(
    actions
    is [
      Event(H3HeadersReceived(0L, _, false, false)),
      Event(H3MessageFinished(0L)),
    ],
  )
  let settings = @http3.encode_http3_frame(H3SettingsFrame([])).unwrap()
  assert_true(
    driver.on_stream_data(2L, b"\x00" + settings, false).unwrap()
    is [Event(H3PeerSettingsReceived(_))],
  )
}

///|
test "http3 driver: QPACK replay delivers a ready sibling when another message fails" {
  let qpack_limits = @http3.QpackLimits::new(
    max_table_capacity=220,
    max_blocked_streams=2,
  ).unwrap()
  let driver = @http3.Http3Driver::new(H3Server, qpack_limits~).unwrap()
  let settings = @http3.encode_http3_frame(H3SettingsFrame([])).unwrap()
  ignore(driver.on_stream_data(2L, b"\x00" + settings, false).unwrap())
  let static_prefix = @http3.qpack_encode_static([
    qpack_test_field(":method", "GET"),
    qpack_test_field(":scheme", "https"),
  ]).unwrap()
  let section = b"\x03\x81" + static_prefix[2:].to_owned() + b"\x10\x11"
  let request_frame = @http3.encode_http3_frame(H3Headers(section)).unwrap()
  assert_eq(driver.on_stream_data(0L, request_frame, true), Ok([]))
  // Both sections wait for the same encoder update. One request declares
  // a one-byte body and ends without it; the other request is complete.
  let bad_prefix = @http3.qpack_encode_static([
    qpack_test_field(":method", "POST"),
    qpack_test_field(":scheme", "https"),
  ]).unwrap()
  let length_field = @http3.qpack_encode_static([
    qpack_test_field("content-length", "1"),
  ]).unwrap()
  let bad_section = b"\x03\x81" +
    bad_prefix[2:].to_owned() +
    b"\x10\x11" +
    length_field[2:].to_owned()
  assert_eq(
    driver.on_stream_data(
      4L,
      @http3.encode_http3_frame(H3Headers(bad_section)).unwrap(),
      true,
    ),
    Ok([]),
  )
  let instructions = b"\x3f\xbd\x01\xc0\x0fwww.example.com\xc1\x0c/sample/path"
  let actions = driver
    .on_stream_data(6L, b"\x02" + instructions, false)
    .unwrap()
  assert_true(actions.any(fn(action) { action is QpackStreamReady(0L) }))
  assert_true(
    actions.any(fn(action) {
      action is Event(H3HeadersReceived(0L, _, false, false))
    }),
  )
  assert_true(actions.contains(Event(H3MessageFinished(0L))))
  assert_true(actions.contains(ResetStream(4L, H3MessageError)))
  assert_eq(driver.connection().stream_phase(4L), None)
  assert_eq(driver.connection().stream_phase(0L), None)
}

///|
test "http3 driver: blocked QPACK frame bytes are bounded and reclaimed" {
  let limits = @types.Limits::new(
    max_start_line=4,
    max_header_line=4,
    max_header_bytes=4,
    max_buffer_bytes=32,
    max_dynamic_table_bytes=32,
  ).unwrap()
  let qpack_limits = @http3.QpackLimits::new(
    max_encoded_field_section_bytes=4,
    max_decoded_field_section_bytes=4,
    max_field_count=4,
    max_table_capacity=32,
    max_blocked_streams=1,
    max_instruction_buffer_bytes=32,
  ).unwrap()
  let driver = @http3.Http3Driver::new(H3Server, limits~, qpack_limits~).unwrap()
  let settings = @http3.encode_http3_frame(H3SettingsFrame([])).unwrap()
  ignore(driver.on_stream_data(2L, b"\x00" + settings, false).unwrap())
  // Required Insert Count 1, Base 0, with no field lines: the section is
  // valid but remains blocked until the encoder inserts an entry.
  let blocked_frame = @http3.encode_http3_frame(H3Headers(b"\x02\x00")).unwrap()
  for _ in 0..<8 {
    assert_eq(driver.on_stream_data(0L, blocked_frame, false), Ok([]))
  }
  assert_true(
    driver.on_stream_data(0L, blocked_frame, false)
    is Err(Http3LimitExceeded("HTTP/3 blocked QPACK frames", 32)),
  )
  ignore(driver.cancel_request_stream(0L).unwrap())
  // Cancellation releases both the QPACK blocked-stream slot and the retained
  // frame-byte budget, so a new request stream can be blocked normally.
  assert_true(driver.on_stream_data(4L, blocked_frame, false) is Ok(_))
}

///|
test "http3 driver: DATA crosses buffer and header limits and a truncated FIN stays terminal" {
  let limits = @types.Limits::new(
    max_start_line=32,
    max_header_line=32,
    max_header_bytes=256,
    max_buffer_bytes=256,
    max_body_bytes=2048,
  ).unwrap()
  let qpack_limits = @http3.QpackLimits::from_http_limits(limits).unwrap()
  let driver = @http3.Http3Driver::new(H3Server, limits~, qpack_limits~).unwrap()
  let head = @http3.encode_http3_frame(
    H3Headers(@http3.qpack_encode_static(driver_request_fields()).unwrap()),
  ).unwrap()
  let body = Bytes::from_array(FixedArray::make(1024, b'x'))
  let data = @http3.encode_http3_frame(H3Data(body)).unwrap()
  let first = driver
    .on_stream_data(0L, head + data[:40].to_owned(), false)
    .unwrap()
  assert_true(first.any(fn(a) { a is Event(H3DataReceived(0L, _)) }))
  let all = first.copy()
  all.append(driver.on_stream_data(0L, data[40:].to_owned(), true).unwrap())
  let received = []
  for a in all {
    if a is Event(H3DataReceived(0L, chunk)) {
      received.append(chunk.to_array())
    }
  }
  assert_eq(Bytes::from_array(received), body)
  assert_eq(all.last(), Some(Event(H3MessageFinished(0L))))
  assert_true(
    driver.on_stream_data(4L, head + data[:40].to_owned(), true)
    is Err(Http3ConnectionError(H3FrameError, _)),
  )
  assert_true(
    driver.on_stream_data(8L, head, false)
    is Err(Http3ConnectionError(H3FrameError, _)),
  )
}
