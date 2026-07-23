///|
test "http2 request semantics reject duplicate and uppercase pseudo headers" {
  let duplicate : Array[@http2.HpackHeader] = [
    { name: ":method", value: "GET" },
    { name: ":method", value: "POST" },
    { name: ":scheme", value: "http" },
    { name: ":authority", value: "example.test" },
    { name: ":path", value: "/" },
  ]
  assert_eq(
    decode_h2_request(1, duplicate) is Err(StreamError(1, ProtocolError, _)),
    true,
  )
  let uppercase : Array[@http2.HpackHeader] = [
    { name: ":method", value: "GET" },
    { name: ":scheme", value: "http" },
    { name: ":authority", value: "example.test" },
    { name: ":path", value: "/" },
    { name: "X-Test", value: "bad" },
  ]
  assert_eq(
    decode_h2_request(1, uppercase) is Err(StreamError(1, ProtocolError, _)),
    true,
  )
}

///|
test "http2 request semantics require authority and constrain TE" {
  let missing_authority : Array[@http2.HpackHeader] = [
    { name: ":method", value: "GET" },
    { name: ":scheme", value: "http" },
    { name: ":path", value: "/" },
  ]
  assert_eq(
    decode_h2_request(1, missing_authority)
    is Err(StreamError(1, ProtocolError, _)),
    true,
  )
  let bad_te : Array[@http2.HpackHeader] = [
    { name: ":method", value: "GET" },
    { name: ":scheme", value: "http" },
    { name: ":authority", value: "example.test" },
    { name: ":path", value: "/" },
    { name: "te", value: "gzip" },
  ]
  assert_eq(
    decode_h2_request(1, bad_te) is Err(StreamError(1, ProtocolError, _)),
    true,
  )
}
