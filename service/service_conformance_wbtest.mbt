///|
test "http2 request semantics reject duplicate and uppercase pseudo headers" {
  let duplicate : Array[@http2.HpackHeader] = [
    { name: ":method", value: b"GET", },
    { name: ":method", value: b"POST", },
    { name: ":scheme", value: b"http", },
    { name: ":authority", value: b"example.test", },
    { name: ":path", value: b"/", },
  ]
  assert_eq(
    decode_h2_request(1, duplicate) is Err(StreamError(1, ProtocolError, _)),
    true,
  )
  let uppercase : Array[@http2.HpackHeader] = [
    { name: ":method", value: b"GET", },
    { name: ":scheme", value: b"http", },
    { name: ":authority", value: b"example.test", },
    { name: ":path", value: b"/", },
    { name: "X-Test", value: b"bad", },
  ]
  assert_eq(
    decode_h2_request(1, uppercase) is Err(StreamError(1, ProtocolError, _)),
    true,
  )
}

///|
test "http2 request semantics require authority and constrain TE" {
  let missing_authority : Array[@http2.HpackHeader] = [
    { name: ":method", value: b"GET", },
    { name: ":scheme", value: b"http", },
    { name: ":path", value: b"/", },
  ]
  assert_eq(
    decode_h2_request(1, missing_authority)
    is Err(StreamError(1, ProtocolError, _)),
    true,
  )
  let bad_te : Array[@http2.HpackHeader] = [
    { name: ":method", value: b"GET", },
    { name: ":scheme", value: b"http", },
    { name: ":authority", value: b"example.test", },
    { name: ":path", value: b"/", },
    { name: "te", value: b"gzip", },
  ]
  assert_eq(
    decode_h2_request(1, bad_te) is Err(StreamError(1, ProtocolError, _)),
    true,
  )
}

///|
test "service h2 preserves opaque regular values and validates pseudo text" {
  let fields : Array[@http2.HpackHeader] = [
    { name: ":method", value: b"GET", },
    { name: ":scheme", value: b"http", },
    { name: ":authority", value: b"example.test", },
    { name: ":path", value: b"/", },
    { name: "x-opaque", value: Bytes::from_array([0x80, 0xff]), },
  ]
  let request = decode_h2_request(1, fields).unwrap()
  assert_eq(request.headers.get_string("x-opaque").unwrap().bytes, b"\x80\xff")
  assert_eq(request.headers.get_all_string("host").length(), 1)
  let invalid : Array[@http2.HpackHeader] = [
    { name: ":method", value: Bytes::from_array([0xff]), },
    { name: ":scheme", value: b"http", },
    { name: ":authority", value: b"example.test", },
    { name: ":path", value: b"/", },
  ]
  assert_true(
    decode_h2_request(3, invalid) is Err(StreamError(3, ProtocolError, _)),
  )
}

///|
test "service h2 CONNECT retains authority-form target" {
  let fields : Array[@http2.HpackHeader] = [
    { name: ":method", value: b"CONNECT", },
    { name: ":authority", value: b"example.test:443", },
  ]
  let request = decode_h2_request(1, fields).unwrap()
  assert_eq(request.uri.form, AuthorityForm)
  assert_eq(request.uri.authority.unwrap().port, Some(443))
}

///|
test "service h2 rejects authority ambiguity and absolute :path" {
  let mismatch : Array[@http2.HpackHeader] = [
    { name: ":method", value: b"GET", },
    { name: ":scheme", value: b"https", },
    { name: ":authority", value: b"example.test", },
    { name: ":path", value: b"/", },
    { name: "host", value: b"attacker.test", },
  ]
  assert_true(
    decode_h2_request(1, mismatch) is Err(StreamError(1, ProtocolError, _)),
  )
  let absolute_path : Array[@http2.HpackHeader] = [
    { name: ":method", value: b"GET", },
    { name: ":scheme", value: b"https", },
    { name: ":authority", value: b"example.test", },
    { name: ":path", value: b"https://attacker.test/", },
  ]
  assert_true(
    decode_h2_request(3, absolute_path) is Err(StreamError(3, ProtocolError, _)),
  )
}

///|
test "service h2 rejects malformed IP-literal authority" {
  let invalid : Array[@http2.HpackHeader] = [
    { name: ":method", value: b"GET", },
    { name: ":scheme", value: b"https", },
    { name: ":authority", value: b"[not-an-ip]", },
    { name: ":path", value: b"/", },
  ]
  assert_true(
    decode_h2_request(5, invalid) is Err(StreamError(5, ProtocolError, _)),
  )
}
