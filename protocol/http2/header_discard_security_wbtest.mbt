///|
fn discard_test_frame(
  typ : Int,
  id : Int,
  flags : Int,
  bytes : Array[Byte],
) -> H2Frame {
  {
    header: { typ, stream_id: id, flags, length: bytes.length(), },
    payload: bytes,
  }
}

///|
test "h2 refused headers retain bounded continuation and compression actions" {
  let connection = H2Connection::new(Server, limits={
    ..@types.Limits::defaults(),
    max_concurrent_requests: 1,
    max_header_bytes: 8,
  })
  ignore(
    connection
    .receive(discard_test_frame(H2_FRAME_HEADERS, 1, H2_FLAGS_END_HEADERS, []))
    .unwrap(),
  )
  assert_true(
    connection.receive(discard_test_frame(H2_FRAME_HEADERS, 3, 0, [0x40]))
    is Ok([HeadersDiscarded(3, false, RefusedStream)]),
  )
  assert_true(
    connection.receive(
      discard_test_frame(H2_FRAME_CONTINUATION, 3, H2_FLAGS_END_HEADERS, [
        1, 120, 1, 118,
      ]),
    )
    is Ok([HeadersContinued(3, true)]),
  )
  assert_true(
    connection.receive(discard_test_frame(H2_FRAME_HEADERS, 5, 0, [0x40]))
    is Ok([HeadersDiscarded(5, false, RefusedStream)]),
  )
  assert_true(
    connection.receive(
      discard_test_frame(H2_FRAME_CONTINUATION, 5, H2_FLAGS_END_HEADERS, [
        0, 0, 0, 0, 0, 0, 0, 0,
      ]),
    )
    is Err(ConnectionError(EnhanceYourCalm, _)),
  )
}

///|
test "h2 closed headers require decode and prohibit interleaved continuation" {
  let connection = H2Connection::new(Server)
  ignore(
    connection
    .receive(
      discard_test_frame(
        H2_FRAME_HEADERS,
        1,
        H2_FLAGS_END_HEADERS | H2_FLAGS_END_STREAM,
        [],
      ),
    )
    .unwrap(),
  )
  assert_true(
    connection.receive(discard_test_frame(H2_FRAME_HEADERS, 1, 0, [0x40]))
    is Ok([HeadersDiscarded(1, false, StreamClosed)]),
  )
  assert_true(
    connection.receive(
      discard_test_frame(H2_FRAME_HEADERS, 3, H2_FLAGS_END_HEADERS, []),
    )
    is Err(ConnectionError(ProtocolError, _)),
  )
}

///|
test "hpack short literal fields after a large update prefix preserve decoding" {
  let block : Array[Byte] = []
  for _ in 0..<60000 {
    block.push(0x20)
  }
  for _ in 0..<1000 {
    block.append([0, 1, 120, 1, 118])
  }
  let decoded = HpackContext::new().decode(Bytes::from_array(block)).unwrap()
  assert_eq(decoded.length(), 1000)
  assert_true(
    decoded.all(fn(header) { header.name == "x" && header.value == b"v" }),
  )
  // Both indexed-name and literal-name paths also retain Huffman validation.
  let encoded : Array[Byte] = [0]
  encoded.append(encode_string(b"x-custom", use_huffman=true))
  encoded.append(encode_string(b"a literal value", use_huffman=true))
  assert_eq(HpackContext::new().decode(Bytes::from_array(encoded)).unwrap(), [
    { name: "x-custom", value: b"a literal value", },
  ])
}
