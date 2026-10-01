///|
test "hpack settings: zero table size evicts and prohibits dynamic references" {
  let encoder = @http2.HpackContext::new()
  let incoming = @http2.HpackContext::new()
  let headers : Array[@http2.HpackHeader] = [
    { name: "x-repeat", value: b"value", },
  ]
  let initial = encoder.encode_incremental(headers).unwrap()
  assert_eq(incoming.decode(initial).unwrap(), headers)
  encoder.set_encoder_table_size(0)
  assert_eq(encoder.table_length(), 0)
  let peer = @http2.HpackContext::new(max_table_size=0)
  let first = encoder.encode_incremental(headers).unwrap()
  assert_eq(first[0], b'\x20')
  assert_eq(peer.decode(first).unwrap(), headers)
  assert_eq(
    peer.decode(encoder.encode_incremental(headers).unwrap()).unwrap(),
    headers,
  )
  assert_eq(encoder.table_length(), 0)
  assert_eq(peer.table_length(), 0)
  // An unrelated receiving context keeps its own dynamic table.
  assert_eq(incoming.decode(b"\xbe").unwrap(), headers)
}

///|
test "hpack settings: consecutive changes emit minimum then final before fields" {
  let encoder = @http2.HpackContext::new()
  let decoder = @http2.HpackContext::new()
  let headers : Array[@http2.HpackHeader] = [
    { name: "x-old", value: b"value", },
  ]
  assert_eq(
    decoder.decode(encoder.encode_incremental(headers).unwrap()).unwrap(),
    headers,
  )
  encoder.set_encoder_table_size(128)
  encoder.set_encoder_table_size(0)
  encoder.set_encoder_table_size(256)
  let block = encoder.encode_incremental(headers).unwrap()
  // RFC 7541 integer encodings for 0 and 256, followed by a literal field.
  assert_true(block.has_prefix(b"\x20\x3f\xe1\x01\x40"))
  assert_eq(decoder.decode(block).unwrap(), headers)
  assert_eq(decoder.table_length(), 1)
  assert_eq(encoder.encode_incremental(headers).unwrap(), b"\xbe")
}

///|
test "hpack settings: rejected header block preserves pending size update" {
  let encoder = @http2.HpackContext::new()
  encoder.set_encoder_table_size(0)
  assert_true(
    encoder.encode_incremental([{ name: "Bad", value: b"x", }]) is Err(_),
  )
  assert_eq(encoder.encode_incremental([]).unwrap(), b"\x20")
  assert_eq(encoder.encode_incremental([]).unwrap(), b"")
}

///|
test "http2 settings: frame and h2c field return the same ordered encoder actions" {
  let settings = @http2.encode_settings_frame(
    [{ id: 1, value: 0, }, { id: 1, value: 256, }],
    false,
  )
  let frames = @http2.FrameDecoder::new()
  frames.feed(Bytes::from_array(settings)).unwrap()
  let frame = frames.next().unwrap().unwrap()
  let from_frame = @http2.H2Connection::new(Server).receive(frame).unwrap()
  assert_true(
    from_frame
    is [PeerHeaderTableSize(0), PeerHeaderTableSize(256), SendSettingsAck],
  )
  let from_upgrade = @http2.H2Connection::new(Server)
    .apply_settings_payload(Bytes::from_array(frame.payload))
    .unwrap()
  assert_true(
    from_upgrade is [PeerHeaderTableSize(0), PeerHeaderTableSize(256)],
  )
}
