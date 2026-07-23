///|
fn test_frame(
  typ : Int,
  flags : Int,
  stream_id : Int,
  payload : Array[Byte],
) -> H2Frame {
  { header: { length: payload.length(), typ, flags, stream_id }, payload }
}

///|
test "h2 runtime: multiplexes remote streams and enforces ordering" {
  let connection = H2Connection::new(Server)
  let first = connection
    .receive(test_frame(H2_FRAME_HEADERS, H2_FLAGS_END_HEADERS, 1, []))
    .unwrap()
  assert_eq(first is [HeadersStarted(1, false)], true)
  let third = connection
    .receive(
      test_frame(
        H2_FRAME_HEADERS,
        H2_FLAGS_END_HEADERS | H2_FLAGS_END_STREAM,
        3,
        [],
      ),
    )
    .unwrap()
  assert_eq(third is [HeadersStarted(3, true)], true)
  assert_eq(connection.stream_state(1), Some(Open))
  assert_eq(connection.stream_state(3), Some(HalfClosedRemote))
  assert_eq(
    connection.receive(
      test_frame(H2_FRAME_HEADERS, H2_FLAGS_END_HEADERS, 1, []),
    )
    is Ok(_),
    true,
  )
  assert_eq(
    connection.receive(
      test_frame(H2_FRAME_HEADERS, H2_FLAGS_END_HEADERS, 2, []),
    )
    is Err(ConnectionError(ProtocolError, _)),
    true,
  )
}

///|
test "h2 runtime: continuation cannot be interleaved" {
  let connection = H2Connection::new(Server)
  ignore(connection.receive(test_frame(H2_FRAME_HEADERS, 0, 1, [])).unwrap())
  assert_eq(
    connection.receive(
      test_frame(H2_FRAME_PING, 0, 0, [0, 0, 0, 0, 0, 0, 0, 0]),
    )
    is Err(ConnectionError(ProtocolError, _)),
    true,
  )
  assert_eq(
    connection.receive(
      test_frame(H2_FRAME_CONTINUATION, H2_FLAGS_END_HEADERS, 1, []),
    )
    is Ok(_),
    true,
  )
}

///|
test "h2 runtime: connection and stream flow control" {
  let connection = H2Connection::new(Server)
  ignore(
    connection
    .receive(test_frame(H2_FRAME_HEADERS, H2_FLAGS_END_HEADERS, 1, []))
    .unwrap(),
  )
  let payload : Array[Byte] = []
  payload.resize(1024, 0)
  let actions = connection
    .receive(test_frame(H2_FRAME_DATA, 0, 1, payload))
    .unwrap()
  assert_eq(actions is [DataReceived(1, _, false, 1024)], true)
  assert_eq(connection.release_capacity(1, 1024).unwrap().length(), 2)
}

///|
test "h2 runtime: SETTINGS validates and adjusts stream window" {
  let connection = H2Connection::new(Client)
  let stream = connection.open_local_stream().unwrap()
  assert_eq(stream, 1)
  let settings = encode_settings_frame([{ id: 4, value: 70000 }], false)
  let decoder = FrameDecoder::new()
  decoder.feed(Bytes::from_array(settings)).unwrap()
  let frame = decoder.next().unwrap().unwrap()
  assert_eq(connection.receive(frame).unwrap() is [SendSettingsAck], true)
  assert_eq(
    connection.reserve_send_capacity(1, 70000).unwrap(),
    H2_DEFAULT_MAX_FRAME_SIZE,
  )
}

///|
test "h2 runtime: invalid control frames are rejected" {
  let connection = H2Connection::new(Server)
  let settings_ack_with_payload = test_frame(
    H2_FRAME_SETTINGS,
    H2_FLAGS_ACK,
    0,
    [1],
  )
  assert_eq(
    connection.receive(settings_ack_with_payload)
    is Err(ConnectionError(FrameSizeError, _)),
    true,
  )
  assert_eq(
    connection.receive(test_frame(H2_FRAME_DATA, 0, 0, []))
    is Err(ConnectionError(ProtocolError, _)),
    true,
  )
  assert_eq(
    connection.receive(test_frame(H2_FRAME_WINDOW_UPDATE, 0, 0, [0, 0, 0, 0]))
    is Err(ConnectionError(ProtocolError, _)),
    true,
  )
  assert_eq(
    connection.receive(test_frame(H2_FRAME_RST_STREAM, 0, 1, [0, 0, 0, 8]))
    is Err(ConnectionError(ProtocolError, _)),
    true,
  )
  assert_eq(
    connection.receive(test_frame(H2_FRAME_PUSH_PROMISE, 0, 1, []))
    is Err(ConnectionError(ProtocolError, _)),
    true,
  )
}

///|
test "hpack dynamic: RFC-style repeated literal becomes indexed" {
  let encoder = HpackContext::new()
  let decoder = HpackContext::new()
  let headers : Array[HpackHeader] = [
    { name: "custom-key", value: "custom-value" },
  ]
  let first = encoder.encode_incremental(headers).unwrap()
  let decoded = decoder.decode(first).unwrap()
  assert_eq(decoded[0].name, "custom-key")
  assert_eq(decoded[0].value, "custom-value")
  assert_eq(encoder.table_length(), 1)
  assert_eq(decoder.table_length(), 1)
  let second = encoder.encode_incremental(headers).unwrap()
  assert_eq(second.length(), 1)
  assert_eq(decoder.decode(second).unwrap()[0].value, "custom-value")
}

///|
test "hpack dynamic: rejects table update beyond peer setting" {
  let decoder = HpackContext::new(max_table_size=32)
  assert_eq(
    decoder.decode(b"\x3f\x02") is Err(ConnectionError(CompressionError, _)),
    true,
  )
}

///|
test "hpack huffman: RFC 7541 C.4.1 www.example.com vector" {
  let raw = @utf8.encode("www.example.com").to_array()
  let expected : Array[Byte] = [
    0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff,
  ]
  assert_eq(hpack_huffman_encode(raw).unwrap(), expected)
  assert_eq(hpack_huffman_decode(expected).unwrap(), raw)
}
