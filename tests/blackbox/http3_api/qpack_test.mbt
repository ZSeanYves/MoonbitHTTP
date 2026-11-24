///|
fn qpack_test_field(name : String, value : String) -> @http3.QpackField {
  @http3.QpackField::from_strings(name, value).unwrap()
}

///|
test "qpack: debug output redacts sensitive field values" {
  let secret = @http3.QpackField::from_strings(
    "authorization", "Bearer production-secret",
  ).unwrap()
  let rendered = @debug.render(@debug.Debug::to_repr(secret))
  assert_true(rendered.contains("<redacted>"))
  assert_false(rendered.contains("production-secret"))
}

///|
test "qpack: RFC 9204 literal with static name reference" {
  let decoder = @http3.QpackDecoder::new().unwrap()
  let section = b"\x00\x00\x51\x0b/index.html"
  match decoder.decode_field_section(0L, section) {
    Ok(QpackDecoded(fields, false)) => {
      assert_eq(fields.length(), 1)
      assert_eq(fields[0].name, ":path")
      assert_eq(fields[0].value, b"/index.html")
    }
    _ => fail("unexpected RFC 9204 decode result")
  }
}

///|
test "qpack: static and literal fields round-trip with opaque bytes" {
  let binary = @http3.QpackField::new("x-binary", b"\x80\xff").unwrap()
  let secret = @http3.QpackField::from_strings("authorization", "Bearer secret").unwrap()
  let fields = [
    qpack_test_field(":method", "GET"),
    qpack_test_field(":scheme", "https"),
    qpack_test_field(":authority", "example.com"),
    qpack_test_field(":path", "/resource"),
    binary,
    secret,
  ]
  let encoded = @http3.qpack_encode_static(fields).unwrap()
  let decoder = @http3.QpackDecoder::new().unwrap()
  match decoder.decode_field_section(0L, encoded) {
    Ok(QpackDecoded(decoded, false)) => {
      assert_eq(decoded, fields)
      assert_true(decoded[5].sensitive)
    }
    _ => fail("unexpected QPACK round-trip result")
  }
}

///|
test "qpack: invalid static index and malformed Huffman are rejected" {
  let decoder = @http3.QpackDecoder::new().unwrap()
  assert_true(
    decoder.decode_field_section(0L, b"\x00\x00\xff\x24")
    is Err(Http3ConnectionError(QpackDecompressionFailed, _)),
  )
  let decoder = @http3.QpackDecoder::new().unwrap()
  assert_true(
    decoder.decode_field_section(0L, b"\x00\x00\x29\xff\xff\xff\xff\x00")
    is Err(Http3ConnectionError(QpackDecompressionFailed, _)),
  )
}

///|
test "qpack: dynamic encoder and decoder synchronize without blocking" {
  let limits = @http3.QpackLimits::new(
    max_table_capacity=256,
    max_blocked_streams=2,
  ).unwrap()
  let encoder = @http3.QpackEncoder::new(limits~).unwrap()
  let decoder = @http3.QpackDecoder::new(limits~).unwrap()
  let capacity = encoder.set_capacity(256).unwrap()
  for index in 0..<capacity.length() {
    decoder.feed_encoder_stream(capacity[index:index + 1]).unwrap()
  }
  let field = qpack_test_field("x-dynamic", "alpha")
  let (instruction, _) = encoder.insert(field).unwrap()
  for index in 0..<instruction.length() {
    decoder.feed_encoder_stream(instruction[index:index + 1]).unwrap()
  }
  assert_eq(decoder.total_inserts(), 1L)
  let increment = @http3.qpack_insert_count_increment(1L).unwrap()
  encoder.feed_decoder_stream(increment).unwrap()
  assert_eq(encoder.known_received_count(), 1L)
  let section = encoder.encode_field_section(0L, [field]).unwrap()
  match decoder.decode_field_section(0L, section) {
    Ok(QpackDecoded(fields, true)) => assert_eq(fields, [field])
    _ => fail("unexpected dynamic decode result")
  }
  encoder
  .feed_decoder_stream(@http3.qpack_section_acknowledgment(0L).unwrap())
  .unwrap()
  assert_true(encoder.set_capacity(0) is Ok(_))
  assert_eq(decoder.finish_encoder_stream(), Ok(()))
  assert_eq(encoder.finish_decoder_stream(), Ok(()))
}

///|
test "qpack: pending dynamic sections have a bounded metadata budget" {
  let limits = @http3.QpackLimits::new(
    max_table_capacity=64,
    max_instruction_buffer_bytes=64,
  ).unwrap()
  let encoder = @http3.QpackEncoder::new(limits~).unwrap()
  let decoder = @http3.QpackDecoder::new(limits~).unwrap()
  for byte in encoder.set_capacity(64).unwrap() {
    decoder.feed_encoder_stream(Bytes::from_array([byte])).unwrap()
  }
  let field = @http3.QpackField::from_strings("x-dynamic", "a").unwrap()
  let (instruction, _) = encoder.insert(field).unwrap()
  for byte in instruction {
    decoder.feed_encoder_stream(Bytes::from_array([byte])).unwrap()
  }
  encoder
  .feed_decoder_stream(@http3.qpack_insert_count_increment(1L).unwrap())
  .unwrap()
  assert_true(encoder.encode_field_section(0L, [field]) is Ok(_))
  assert_true(encoder.encode_field_section(0L, [field]) is Ok(_))
  assert_eq(encoder.pending_bytes(), 48)
  assert_true(
    encoder.encode_field_section(0L, [field])
    is Err(Http3LimitExceeded("QPACK pending field sections", 64)),
  )
  encoder
  .feed_decoder_stream(@http3.qpack_section_acknowledgment(0L).unwrap())
  .unwrap()
  assert_eq(encoder.pending_bytes(), 24)
  encoder
  .feed_decoder_stream(@http3.qpack_stream_cancellation(0L).unwrap())
  .unwrap()
  assert_eq(encoder.pending_bytes(), 0)
  assert_true(encoder.encode_field_section(0L, [field]) is Ok(_))
}

///|
test "qpack: RFC dynamic post-Base example blocks and later unblocks" {
  let limits = @http3.QpackLimits::new(
    max_table_capacity=220,
    max_blocked_streams=1,
  ).unwrap()
  let decoder = @http3.QpackDecoder::new(limits~).unwrap()
  let section = b"\x03\x81\x10\x11"
  assert_eq(decoder.decode_field_section(0L, section), Ok(QpackBlocked(2L)))
  assert_true(
    decoder.decode_field_section(4L, section)
    is Err(Http3ConnectionError(QpackDecompressionFailed, _)),
  )
  let instructions = b"\x3f\xbd\x01\xc0\x0fwww.example.com\xc1\x0c/sample/path"
  decoder.feed_encoder_stream(instructions).unwrap()
  assert_eq(decoder.ready_blocked_streams(), [0L])
  match decoder.decode_field_section(0L, section) {
    Ok(QpackDecoded(fields, true)) => {
      assert_eq(fields.length(), 2)
      assert_eq(fields[0].name, ":authority")
      assert_eq(fields[0].value, b"www.example.com")
      assert_eq(fields[1].name, ":path")
      assert_eq(fields[1].value, b"/sample/path")
    }
    _ => fail("unexpected RFC dynamic result")
  }
}

///|
test "qpack: instruction truncation and terminal failures are preserved" {
  let limits = @http3.QpackLimits::new(max_table_capacity=64).unwrap()
  let decoder = @http3.QpackDecoder::new(limits~).unwrap()
  decoder.feed_encoder_stream(b"\x3f").unwrap()
  assert_true(
    decoder.finish_encoder_stream()
    is Err(Http3ConnectionError(QpackEncoderStreamError, _)),
  )
  assert_true(
    decoder.feed_encoder_stream(b"\x00")
    is Err(Http3ConnectionError(QpackEncoderStreamError, _)),
  )
  let encoder = @http3.QpackEncoder::new(limits~).unwrap()
  assert_true(
    encoder.feed_decoder_stream(b"\x00")
    is Err(Http3ConnectionError(QpackDecoderStreamError, _)),
  )
  assert_true(
    encoder.feed_decoder_stream(b"\x01")
    is Err(Http3ConnectionError(QpackDecoderStreamError, _)),
  )
}
