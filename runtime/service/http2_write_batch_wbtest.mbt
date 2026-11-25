///|
async test "one granted write carries complete ordered DATA frames within the peer frame limit" {
  let body = Bytes::makei(4 * @http2.H2_DEFAULT_MAX_FRAME_SIZE, i => {
    (i % 251).to_byte()
  })
  let available = 2 * @http2.H2_DEFAULT_MAX_FRAME_SIZE + 3
  let writes : Array[Bytes] = []
  let length = write_h2_data_chunk(
    3,
    body[:],
    Mutex(),
    requested => requested.min(available),
    () => fail("available credit must not wait"),
    bytes => writes.push(bytes),
  )
  assert_eq(length, available)
  assert_eq(writes.length(), 1)
  let decoder = @http2.FrameDecoder::new()
  decoder.feed(writes[0]).unwrap()
  let mut offset = 0
  for size in [16384, 16384, 3] {
    let frame = decoder.next().unwrap().unwrap()
    assert_eq(
      (frame.header.stream_id, frame.header.typ, frame.header.flags),
      (3, @http2.H2_FRAME_DATA, 0),
    )
    assert_eq(frame.header.length, size)
    assert_eq(
      Bytes::from_array(frame.payload),
      body[offset:offset + size].to_owned(),
    )
    offset += size
  }
  assert_true(decoder.next().unwrap() is None)
}
