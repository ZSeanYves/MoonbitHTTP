///|
test "http3 QPACK: maximum-size coalesced no-op instruction streams" {
  let driver = @http3.Http3Driver::new(H3Server).unwrap()
  let data = FixedArray::make(64 * 1024 + 1, b'\x20')
  data[0] = b'\x02'
  let wire = Bytes::from_array(data)
  // An attacker can make ordinary datagram-sized fragments coalesce into one
  // large StreamData event by leaving the stream-type byte until last.
  let reassembler = @quic.QuicCryptoReassembler::new().unwrap()
  let mut cursor = 1
  while cursor < wire.length() {
    let end = (cursor + 1100).min(wire.length())
    assert_eq(
      reassembler.feed(cursor.to_int64(), wire[cursor:end].to_owned()),
      Ok([]),
    )
    cursor = end
  }
  let chunks = reassembler.feed(0L, b"\x02").unwrap()
  assert_eq(chunks.length(), 1)
  assert_eq(chunks[0].length(), 64 * 1024 + 1)
  assert_eq(driver.on_stream_data(6L, chunks[0], false), Ok([]))
  assert_eq(driver.connection().qpack_decoder().capacity(), 0)
  // Exercise the independent decoder-instruction parser's one-byte path.
  assert_eq(driver.on_stream_data(10L, b"\x03", false), Ok([]))
  let cancellations = Bytes::from_array(FixedArray::make(64 * 1024, b'\x40'))
  assert_eq(driver.on_stream_data(10L, cancellations, false), Ok([]))
}

///|
test "http3 QPACK: fragmented long literals preserve state and incomplete suffix" {
  let limits = @http3.QpackLimits::new(max_table_capacity=9000).unwrap()
  let encoder = @http3.QpackEncoder::new(limits~).unwrap()
  let decoder = @http3.QpackDecoder::new(limits~).unwrap()
  decoder.feed_encoder_stream(encoder.set_capacity(9000).unwrap()).unwrap()
  let name = @utf8.decode_lossy(Bytes::from_array(FixedArray::make(4000, b'a')))
  let value = Bytes::from_array(FixedArray::make(4000, b'v'))
  let (instruction, _) = encoder
    .insert(@http3.QpackField::new(name, value).unwrap(), use_huffman=false)
    .unwrap()
  // A complete capacity instruction followed by a partial literal leaves
  // exactly the incomplete instruction available for the next feed.
  let prefix = driver_join([
    encoder.set_capacity(9000).unwrap(),
    instruction[:3].to_owned(),
  ])
  decoder.feed_encoder_stream(prefix).unwrap()
  assert_eq(decoder.total_inserts(), 0L)
  for index in 3..<instruction.length() {
    decoder.feed_encoder_stream(instruction[index:index + 1]).unwrap()
  }
  assert_eq(decoder.total_inserts(), 1L)
  assert_eq(decoder.table_size(), 8032)
  decoder.finish_encoder_stream().unwrap()
  // A partial multi-byte cancellation following a consumed instruction must
  // likewise survive compaction in the decoder stream.
  encoder.feed_decoder_stream(b"\x40\x7f").unwrap()
  encoder.feed_decoder_stream(b"\x01").unwrap()
  encoder.finish_decoder_stream().unwrap()
}

///|
test "http3 push: reject ungranted promises before QPACK and reject push streams" {
  let driver = @http3.Http3Driver::new(H3Client).unwrap()
  let settings = @http3.encode_http3_frame(H3SettingsFrame([])).unwrap()
  ignore(
    driver.on_stream_data(3L, driver_join([b"\x00", settings]), false).unwrap(),
  )
  let request = driver.open_request_stream().unwrap()
  // Deliberately malformed QPACK: the push authorization gate must fire first.
  let promise = @http3.encode_http3_frame(H3PushPromise(0L, b"invalid")).unwrap()
  assert_true(
    driver.on_stream_data(request, promise, false)
    is Err(Http3ConnectionError(H3IdError, _)),
  )
  assert_true(
    driver.on_stream_data(15L, b"\x01\x00", false)
    is Err(Http3ConnectionError(H3IdError, _)),
  )
  let server = @http3.Http3Connection::new(H3Server).unwrap()
  assert_true(
    server.register_remote_unidirectional(2L, b"\x01\x00")
    is Err(Http3ConnectionError(H3StreamCreationError, _)),
  )
}
