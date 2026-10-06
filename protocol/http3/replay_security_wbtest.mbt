///|
fn replay_security_driver() -> Http3Driver {
  let limits = @types.Limits::new(
    max_start_line=64,
    max_header_line=64,
    max_header_bytes=256,
    max_buffer_bytes=512,
    max_dynamic_table_bytes=220,
  ).unwrap()
  let qpack_limits = QpackLimits::new(
    max_encoded_field_section_bytes=256,
    max_decoded_field_section_bytes=256,
    max_field_count=8,
    max_table_capacity=220,
    max_blocked_streams=2,
    max_instruction_buffer_bytes=512,
  ).unwrap()
  let driver = Http3Driver::new(H3Server, limits~, qpack_limits~).unwrap()
  ignore(driver.on_stream_data(2L, b"\x00\x04\x00", false).unwrap())
  ignore(driver.on_stream_data(6L, b"\x02\x3f\xbd\x01", false).unwrap())
  driver
}

///|
test "h3 blocked replay releases ownership once on semantic failure and cancellation" {
  let driver = replay_security_driver()
  for index in 0..<3 {
    let id = (index * 4).to_int64()
    let section = Bytes::from_array([(index + 2).to_byte(), b'\x00'])
    let frame = encode_http3_frame(H3Headers(section)).unwrap()
    assert_eq(driver.on_stream_data(id, frame, true), Ok([]))
    assert_eq(driver.blocked_bytes, 4)
    assert_true(
      driver.on_stream_data(6L, b"\x41x\x01v", false)
      is Err(Http3StreamError(id2, H3MessageError, _)) &&
      id2 == id,
    )
    assert_eq(driver.blocked_bytes, 0)
    assert_eq(driver.blocked_frames.length(), 0)
    ignore(driver.cancel_request_stream(id).unwrap())
    ignore(driver.cancel_request_stream(id).unwrap())
    assert_eq(driver.blocked_bytes, 0)
  }
  let blocked = encode_http3_frame(H3Headers(b"\x05\x00")).unwrap()
  assert_eq(driver.on_stream_data(12L, blocked, false), Ok([]))
  let data = encode_http3_frame(
    H3Data(Bytes::from_array(FixedArray::make(250, b'x'))),
  ).unwrap()
  assert_eq(driver.on_stream_data(12L, data, false), Ok([]))
  assert_eq(driver.on_stream_data(12L, data, false), Ok([]))
  // Each 250-byte DATA frame uses a two-byte length varint, so its encoded
  // size is 253 bytes. The blocked HEADERS frame is four bytes: 4 + 253 +
  // 253 = 510. This guards the exact wire-size budget at the 64-byte varint
  // boundary instead of relying on a fixed two-byte header estimate.
  assert_eq(driver.blocked_bytes, 510)
  // A frame type of 64 itself uses a two-byte QUIC varint. Keep that header
  // width in the budget as well as the payload-length width above.
  assert_eq(h3_driver_blocked_frame_bytes(H3Unknown(0x40L, b"abc")), 6)
  let extra = encode_http3_frame(H3Unknown(0x21L, b"abc")).unwrap()
  assert_true(
    driver.on_stream_data(12L, extra, false) is Err(Http3LimitExceeded(_, 512)),
  )
  ignore(driver.cancel_request_stream(12L).unwrap())
  assert_eq(driver.blocked_bytes, 0)
}

///|
test "h3 blocked streams preserve DATA trailers FIN and repeated blocking order" {
  let driver = replay_security_driver()
  let fields = qpack_encode_static([
    QpackField::from_strings(":method", "GET").unwrap(),
    QpackField::from_strings(":scheme", "https").unwrap(),
    QpackField::from_strings(":authority", "example.com").unwrap(),
    QpackField::from_strings(":path", "/").unwrap(),
  ]).unwrap()
  let initial = h3_driver_join([b"\x02\x00", fields[2:].to_owned(), b"\x80"])
  let frames = h3_driver_join([
    encode_http3_frame(H3Headers(initial)).unwrap(),
    encode_http3_frame(H3Data(b"ok")).unwrap(),
    encode_http3_frame(H3Unknown(0x21L, b"extension")).unwrap(),
    encode_http3_frame(H3Headers(b"\x03\x00\x80")).unwrap(),
  ])
  assert_eq(driver.on_stream_data(0L, frames, true), Ok([]))
  let actions = driver.on_stream_data(6L, b"\x41x\x01v", false).unwrap()
  let delivered : Array[String] = []
  for action in actions {
    match action {
      Event(H3HeadersReceived(0L, _, false, false)) => delivered.push("headers")
      Event(H3DataReceived(0L, b"ok")) => delivered.push("data")
      Event(H3UnknownFrameIgnored(0x21L)) => delivered.push("extension")
      _ => ()
    }
  }
  assert_eq(delivered, ["headers", "data", "extension"])
  assert_eq(driver.blocked_bytes, 5)
  assert_eq(driver.connection.stream_phase(0L), Some(H3OpenBody))
  assert_true(driver.pending_fin.contains(0L))
  let actions = driver.on_stream_data(6L, b"\x41y\x01z", false).unwrap()
  assert_true(
    actions.any(fn(action) {
      action is Event(H3HeadersReceived(0L, _, true, false))
    }),
  )
  assert_eq(driver.connection.stream_phase(0L), None)
  assert_eq(driver.blocked_bytes, 0)
  assert_false(driver.pending_fin.contains(0L))
}

///|
test "h3 direct connection does not decode a later static section before blocked headers" {
  let driver = replay_security_driver()
  let connection = driver.connection
  connection.accept_request_stream(0L).unwrap()
  assert_eq(
    connection.receive_request_frame(0L, H3Headers(b"\x02\x00")),
    Ok([]),
  )
  let later = qpack_encode_static([
    QpackField::from_strings(":method", "GET").unwrap(),
    QpackField::from_strings(":scheme", "https").unwrap(),
    QpackField::from_strings(":path", "/").unwrap(),
  ]).unwrap()
  assert_eq(connection.receive_request_frame(0L, H3Headers(later)), Ok([]))
  assert_eq(connection.receive_request_frame(0L, H3Data(b"body")), Ok([]))
  assert_eq(connection.decoder.blocked_stream_count(), 1)
  assert_eq(connection.stream_phase(0L), Some(H3WaitingHeaders))
  ignore(connection.cancel_request_stream(0L).unwrap())
  assert_eq(connection.decoder.blocked_stream_count(), 0)
}
