///|
test "h2 incremental: frame header and payload survive every split" {
  let encoded = @http2.encode_settings_frame([{ id: 3, value: 10, }], false)
  for split in 1..<encoded.length() {
    let decoder = @http2.FrameDecoder::new()
    assert_eq(decoder.feed(Bytes::from_array(encoded)[:split]), Ok(()))
    assert_eq(decoder.next() is Ok(None), true)
    assert_eq(decoder.feed(Bytes::from_array(encoded)[split:]), Ok(()))
    guard decoder.next() is Ok(Some(frame)) else { fail("frame not decoded") }
    assert_eq(frame.header.typ, @http2.H2_FRAME_SETTINGS)
    assert_eq(frame.payload.length(), 6)
  }
}

///|
test "h2 incremental: response encoder emits HEADERS and DATA" {
  let response : @types.Response[Bytes] = {
    status: 200,
    version: Http2,
    headers: @types.HeaderMap::new(),
    body: b"ok",
  }
  let bytes = @http2.encode_response_frames(
    @http2.HpackContext::new(),
    1,
    response,
  ).unwrap()
  let decoder = @http2.FrameDecoder::new()
  assert_eq(decoder.feed(bytes), Ok(()))
  guard decoder.next() is Ok(Some(headers)) else { fail("missing HEADERS") }
  guard decoder.next() is Ok(Some(data)) else { fail("missing DATA") }
  assert_eq(headers.header.typ, @http2.H2_FRAME_HEADERS)
  assert_eq(data.header.typ, @http2.H2_FRAME_DATA)
  assert_eq((data.header.flags & @http2.H2_FLAGS_END_STREAM) != 0, true)
}

///|
test "h2 incremental: reserved stream-id bit is a connection error" {
  let decoder = @http2.FrameDecoder::new()
  decoder.feed(b"\x00\x00\x00\x04\x00\x80\x00\x00\x00").unwrap()
  guard decoder.next() is Err(first) else { fail("reserved bit was accepted") }
  assert_true(first is ConnectionError(ProtocolError, _))
  assert_eq(decoder.feed(b""), Err(first))
  guard decoder.next() is Err(second) else {
    fail("frame decoder resumed after a terminal error")
  }
  assert_eq(second, first)
}

///|
test "h2 incremental: frame buffer limit is enforced" {
  let decoder = @http2.FrameDecoder::new(max_buffer_size=8)
  assert_eq(
    decoder.feed(b"\x00\x00\x04\x00\x00\x00\x00\x00\x01")
    is Err(ConnectionError(EnhanceYourCalm, _)),
    true,
  )
}
