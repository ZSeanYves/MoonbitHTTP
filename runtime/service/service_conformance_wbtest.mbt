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
  let te : @http2.HpackHeader = { name: "te", value: b"TrAiLeRs", }
  bad_te[4] = te
  assert_true(decode_h2_request(1, bad_te) is Ok(_))
  assert_true(
    decode_http2_response_head(1, [{ name: ":status", value: b"200", }, te])
    is Err(StreamError(1, ProtocolError, _)),
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

///|
test "split Cookie reaches H2 and H3 applications as a single value" {
  for values in [[b"theme=light", b"lang=en"], [b"theme=light; lang=en"]] {
    let fields : Array[@http2.HpackHeader] = [
      { name: ":method", value: b"GET", },
      { name: ":scheme", value: b"https", },
      { name: ":authority", value: b"example.test", },
      { name: ":path", value: b"/", },
    ]
    for value in values {
      fields.push({ name: "cookie", value, })
    }
    let h2 = decode_h2_request(1, fields).unwrap()
    let h3 = h3_request(
      0L,
      fields.map(h => @http3.QpackField::new(h.name, h.value).unwrap()),
      @body.BodyStream::new().unwrap(),
    )
    for headers in [h2.headers, h3.headers] {
      assert_eq(headers.get_all_string("cookie").length(), 1)
      assert_eq(
        headers.get_string("cookie").unwrap().bytes,
        b"theme=light; lang=en",
      )
    }
  }
  let response = decode_http2_response_head(1, [
    { name: ":status", value: b"200", },
    { name: "set-cookie", value: b"a=1", },
    { name: "set-cookie", value: b"b=2", },
  ]).unwrap()
  assert_eq(response.1.get_all_string("set-cookie").length(), 2)
}
