///|
test "h2 incremental: frame header and payload survive every split" {
  let encoded = encode_settings_frame([{ id: 3, value: 10 }], false)
  for split in 1..<encoded.length() {
    let decoder = FrameDecoder::new()
    assert_eq(decoder.feed(Bytes::from_array(encoded)[:split]), Ok(()))
    assert_eq(decoder.next() is Ok(None), true)
    assert_eq(decoder.feed(Bytes::from_array(encoded)[split:]), Ok(()))
    guard decoder.next() is Ok(Some(frame)) else { fail("frame not decoded") }
    assert_eq(frame.header.typ, H2_FRAME_SETTINGS)
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
  let bytes = encode_response_frames(HpackContext::new(), 1, response).unwrap()
  let decoder = FrameDecoder::new()
  assert_eq(decoder.feed(bytes), Ok(()))
  guard decoder.next() is Ok(Some(headers)) else { fail("missing HEADERS") }
  guard decoder.next() is Ok(Some(data)) else { fail("missing DATA") }
  assert_eq(headers.header.typ, H2_FRAME_HEADERS)
  assert_eq(data.header.typ, H2_FRAME_DATA)
  assert_eq((data.header.flags & H2_FLAGS_END_STREAM) != 0, true)
}

///|
test "h2 incremental: reserved stream-id bit is a connection error" {
  let decoder = FrameDecoder::new()
  decoder.feed(b"\x00\x00\x00\x04\x00\x80\x00\x00\x00").unwrap()
  assert_eq(decoder.next() is Err(ConnectionError(ProtocolError, _)), true)
}

///|
test "h2 incremental: frame buffer limit is enforced" {
  let decoder = FrameDecoder::new(max_buffer_size=8)
  assert_eq(
    decoder.feed(b"\x00\x00\x04\x00\x00\x00\x00\x00\x01")
    is Err(ConnectionError(EnhanceYourCalm, _)),
    true,
  )
}
