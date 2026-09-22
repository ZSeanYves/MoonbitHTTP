///|
test "http3 frame: known frames round-trip and preserve opaque payloads" {
  let frames : Array[@http3.Http3Frame] = [
    H3Data(b"body"),
    H3Headers(b"\x00\xff"),
    H3CancelPush(17L),
    H3SettingsFrame([
      { id: @http3.H3_SETTINGS_QPACK_MAX_TABLE_CAPACITY, value: 128L, },
      { id: @http3.H3_SETTINGS_QPACK_BLOCKED_STREAMS, value: 3L, },
    ]),
    H3PushPromise(9L, b"fields"),
    H3Goaway(12L),
    H3MaxPushId(21L),
    H3Unknown(0x21L, b"padding"),
  ]
  for frame in frames {
    let encoded = @http3.encode_http3_frame(frame).unwrap()
    let (decoded, used) = @http3.decode_http3_frame(encoded).unwrap()
    assert_eq(decoded, frame)
    assert_eq(used, encoded.length())
  }
}

///|
test "http3 frame: decoder accepts every single-byte fragmentation" {
  let encoded = @http3.encode_http3_frame(H3Headers(b"fragmented-header-block")).unwrap()
  let decoder = @http3.Http3FrameDecoder::new().unwrap()
  for index in 0..<encoded.length() {
    decoder.feed(encoded[index:index + 1]).unwrap()
    if index + 1 < encoded.length() {
      assert_eq(decoder.next(), Ok(None))
    }
  }
  assert_eq(decoder.next(), Ok(Some(H3Headers(b"fragmented-header-block"))))
  assert_eq(decoder.next(), Ok(None))
  assert_eq(decoder.finish(), Ok(()))
}

///|
test "http3 frame: malformed lengths, settings, and reserved types are terminal" {
  assert_true(
    @http3.decode_http3_frame(b"\x01\x05abc") is Err(Http3NeedMoreInput),
  )
  assert_true(
    @http3.decode_http3_frame(b"\x04\x04\x01\x00\x01\x00")
    is Err(Http3ConnectionError(H3SettingsError, _)),
  )
  assert_true(
    @http3.decode_http3_frame(b"\x02\x00")
    is Err(Http3ConnectionError(H3FrameUnexpected, _)),
  )
  assert_eq(@http3.decode_http3_frame(b"\x40\x01\x00"), Ok((H3Headers(b""), 3)))
  let decoder = @http3.Http3FrameDecoder::new(
    max_buffer_bytes=8,
    max_payload_bytes=8,
  ).unwrap()
  decoder.feed(b"\x01\x09").unwrap()
  assert_true(decoder.next() is Err(Http3LimitExceeded(_, 8)))
  assert_true(decoder.next() is Err(Http3LimitExceeded(_, 8)))
}

///|
test "http3 frame: stream EOF reports partial frame" {
  let decoder = @http3.Http3FrameDecoder::new().unwrap()
  decoder.feed(b"\x00\x04ab").unwrap()
  assert_eq(decoder.next(), Ok(None))
  assert_true(decoder.finish() is Err(Http3UnexpectedEof(_)))
  assert_true(decoder.next() is Err(Http3UnexpectedEof(_)))
}
