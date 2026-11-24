///|
test "h3 SETTINGS large unique lists preserve order through both decoders" {
  let settings : Array[@http3.H3Setting] = []
  for index in 0..<16000 {
    settings.push({ id: (index + 16).to_int64(), value: 0L, })
  }
  let frame = @http3.Http3Frame::H3SettingsFrame(settings)
  let encoded = @http3.encode_http3_frame(frame).unwrap()
  assert_true(encoded.length() < 65536)
  assert_eq(@http3.decode_http3_frame(encoded).unwrap().0, frame)
  let decoder = @http3.Http3FrameDecoder::new().unwrap()
  decoder.feed(encoded[:encoded.length() - 1]).unwrap()
  assert_eq(decoder.next(), Ok(None))
  decoder.feed(encoded[encoded.length() - 1:]).unwrap()
  assert_eq(decoder.next(), Ok(Some(frame)))
  settings.push(settings[0])
  assert_true(
    @http3.encode_http3_frame(H3SettingsFrame(settings))
    is Err(Http3ConnectionError(H3SettingsError, _)),
  )
  // Build a duplicate wire block without relying on the validating encoder.
  let (_, length_width) = @quic.quic_decode_varint(encoded[1:]).unwrap()
  let duplicate_payload = encoded[1 + length_width:].to_owned().to_array()
  duplicate_payload.push(16)
  duplicate_payload.push(0)
  let length = @quic.QuicVarInt::new(duplicate_payload.length().to_int64())
    .unwrap()
    .encode()
  let bytes : Array[Byte] = [4]
  bytes.append(length.to_array())
  bytes.append(duplicate_payload)
  assert_true(
    @http3.decode_http3_frame(Bytes::from_array(bytes))
    is Err(Http3ConnectionError(H3SettingsError, _)),
  )
}

///|
test "h3 SETTINGS direct API rejects duplicate identifiers" {
  let connection = @http3.Http3Connection::new(H3Server).unwrap()
  let duplicate = @http3.Http3Frame::H3SettingsFrame([
    { id: @http3.H3_SETTINGS_QPACK_MAX_TABLE_CAPACITY, value: 0L, },
    { id: @http3.H3_SETTINGS_QPACK_MAX_TABLE_CAPACITY, value: 1L, },
  ])
  assert_true(
    connection.receive_control_frame(duplicate)
    is Err(Http3ConnectionError(H3SettingsError, _)),
  )
}
