///|
test "h2 conformance: frame decoder rejects reserved stream bit" {
  let decoder = FrameDecoder::new()
  decoder.feed(b"\x00\x00\x00\x04\x00\x80\x00\x00\x01").unwrap()
  assert_eq(decoder.next() is Err(ConnectionError(ProtocolError, _)), true)
}

///|
test "h2 conformance: padded DATA exposes only application bytes" {
  let connection = H2Connection::new(Server)
  ignore(
    connection
    .receive({
      header: {
        length: 0,
        typ: H2_FRAME_HEADERS,
        flags: H2_FLAGS_END_HEADERS,
        stream_id: 1,
      },
      payload: [],
    })
    .unwrap(),
  )
  let actions = connection
    .receive({
      header: {
        length: 5,
        typ: H2_FRAME_DATA,
        flags: H2_FLAGS_PADDED,
        stream_id: 1,
      },
      payload: [1, b'a', b'b', b'c', 0],
    })
    .unwrap()
  assert_eq(actions is [DataReceived(1, [b'a', b'b', b'c'], false, 5)], true)
}

///|
test "h2 conformance: malformed padding and self dependencies fail" {
  let connection = H2Connection::new(Server)
  assert_eq(
    connection.receive({
      header: {
        length: 1,
        typ: H2_FRAME_DATA,
        flags: H2_FLAGS_PADDED,
        stream_id: 1,
      },
      payload: [1],
    })
    is Err(ConnectionError(FrameSizeError, _)),
    true,
  )
  assert_eq(
    connection.receive({
      header: {
        length: 5,
        typ: H2_FRAME_HEADERS,
        flags: H2_FLAGS_PRIORITY,
        stream_id: 1,
      },
      payload: [0, 0, 0, 1, 15],
    })
    is Err(ConnectionError(ProtocolError, _)),
    true,
  )
}

///|
test "h2 conformance: server SETTINGS_ENABLE_PUSH is rejected by client" {
  let connection = H2Connection::new(Client)
  let frame : H2Frame = {
    header: { length: 6, typ: H2_FRAME_SETTINGS, flags: 0, stream_id: 0 },
    payload: [0, 2, 0, 0, 0, 1],
  }
  assert_eq(
    connection.receive(frame) is Err(ConnectionError(ProtocolError, _)),
    true,
  )
}

///|
test "h2 conformance: local concurrent stream limit is enforced" {
  let connection = H2Connection::new(Server)
  connection.local_settings.max_concurrent_streams = 1
  ignore(
    connection
    .receive({
      header: {
        length: 0,
        typ: H2_FRAME_HEADERS,
        flags: H2_FLAGS_END_HEADERS,
        stream_id: 1,
      },
      payload: [],
    })
    .unwrap(),
  )
  assert_eq(
    connection.receive({
      header: {
        length: 0,
        typ: H2_FRAME_HEADERS,
        flags: H2_FLAGS_END_HEADERS,
        stream_id: 3,
      },
      payload: [],
    })
    is Err(StreamError(3, RefusedStream, _)),
    true,
  )
}

///|
test "h2 flow control: repeated consume and release does not starve" {
  let connection = H2Connection::new(Server)
  ignore(
    connection
    .receive({
      header: {
        length: 0,
        typ: H2_FRAME_HEADERS,
        flags: H2_FLAGS_END_HEADERS,
        stream_id: 1,
      },
      payload: [],
    })
    .unwrap(),
  )
  let payload : Array[Byte] = []
  payload.resize(1024, 0)
  for _ in 0..<256 {
    ignore(
      connection
      .receive({
        header: {
          length: payload.length(),
          typ: H2_FRAME_DATA,
          flags: 0,
          stream_id: 1,
        },
        payload,
      })
      .unwrap(),
    )
    assert_eq(
      connection.release_capacity(1, payload.length()).unwrap().length(),
      2,
    )
  }
}

///|
test "h2 flow control: exhausted send window resumes after both updates" {
  let connection = H2Connection::new(Client)
  let stream_id = connection.open_local_stream().unwrap()
  assert_eq(connection.reserve_send_capacity(stream_id, 65535).unwrap(), 16384)
  assert_eq(connection.reserve_send_capacity(stream_id, 65535).unwrap(), 16384)
  assert_eq(connection.reserve_send_capacity(stream_id, 65535).unwrap(), 16384)
  assert_eq(connection.reserve_send_capacity(stream_id, 65535).unwrap(), 16383)
  assert_eq(connection.reserve_send_capacity(stream_id, 1).unwrap(), 0)
  ignore(
    connection
    .receive({
      header: { length: 4, typ: H2_FRAME_WINDOW_UPDATE, flags: 0, stream_id: 0 },
      payload: [0, 0, 0x10, 0],
    })
    .unwrap(),
  )
  ignore(
    connection
    .receive({
      header: { length: 4, typ: H2_FRAME_WINDOW_UPDATE, flags: 0, stream_id },
      payload: [0, 0, 0x10, 0],
    })
    .unwrap(),
  )
  assert_eq(connection.reserve_send_capacity(stream_id, 4096).unwrap(), 4096)
}

///|
test "h2 conformance: RST_STREAM encoder uses the RFC error code" {
  let encoded = encode_rst_stream(3, RefusedStream).unwrap()
  let decoder = FrameDecoder::new()
  decoder.feed(encoded).unwrap()
  let frame = decoder.next().unwrap().unwrap()
  assert_eq(frame.header.typ, H2_FRAME_RST_STREAM)
  assert_eq(frame.header.stream_id, 3)
  assert_eq(frame.payload, [0, 0, 0, 7])
}
