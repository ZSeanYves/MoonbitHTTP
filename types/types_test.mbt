///|
test "types: HeaderMap preserves duplicates and normalizes names" {
  let headers = @types.HeaderMap::new()
  assert_eq(headers.append_string("Set-Cookie", "a=1"), Ok(()))
  assert_eq(headers.append_string("set-cookie", "b=2"), Ok(()))
  let values = headers.get_all_string("SET-COOKIE")
  assert_eq(values.length(), 2)
  assert_eq(values[0].to_string_lossy(), "a=1")
  assert_eq(values[1].to_string_lossy(), "b=2")
  assert_eq(headers.fields()[0].name.value, "set-cookie")
  let copied = headers.copy()
  copied.append_string("x-copy", "yes").unwrap()
  assert_true(headers.get_string("x-copy") is None)
  assert_eq(copied.get_string("x-copy").unwrap().to_string_lossy(), "yes")
}

///|
test "types: rejects header injection" {
  assert_eq(
    @types.HeaderValue::from_string("ok\r\ninjected: yes") is Err(_),
    true,
  )
  assert_eq(@types.HeaderName::parse("bad name") is Err(_), true)
}

///|
test "types: header values classify every byte without parser differentials" {
  for value in 0..<256 {
    let result = @types.HeaderValue::from_bytes(
      Bytes::from_array([value.to_byte()]),
    )
    let allowed = value == 0x09 ||
      (value >= 0x20 && value <= 0x7e) ||
      value >= 0x80
    assert_eq(result is Ok(_), allowed)
  }
  assert_eq(@types.HeaderValue::from_bytes(b""), Ok({ bytes: b"", }))
}

///|
test "types: methods are token-validated and case-sensitive" {
  assert_eq(@types.Method::parse("GET"), Ok(Get))
  assert_eq(@types.Method::parse("get"), Ok(Extension("get")))
  assert_eq(@types.Method::parse("M-SEARCH"), Ok(Extension("M-SEARCH")))
  assert_true(@types.Method::parse("") is Err(EmptyMethod))
  assert_true(@types.Method::parse("BAD METHOD") is Err(InvalidMethodToken))
  let noncanonical : @types.Method = Extension("GET")
  let extension : @types.Method = Extension("get")
  assert_true(noncanonical.validate() is Err(NonCanonicalMethod))
  assert_eq(extension.validate(), Ok(()))
}

///|
test "types: URI parsing preserves validated structured components" {
  let uri = @types.Uri::parse("HTTPS://Example.COM:8443/a%20b?q=x/y#part").unwrap()
  assert_eq(uri.scheme, Some("https"))
  assert_eq(uri.form, AbsoluteForm)
  assert_eq(uri.path, "/a%20b")
  assert_eq(uri.query, Some("q=x/y"))
  assert_eq(uri.fragment, Some("part"))
  guard uri.authority is Some(authority) else { fail("authority was lost") }
  assert_eq(authority.host, "example.com")
  assert_eq(authority.port, Some(8443))
  assert_eq(uri.origin_form(), Ok("/a%20b?q=x/y"))
}

///|
test "types: request-target forms are method-sensitive" {
  let connect = @types.Uri::parse_request_target("[2001:db8::1]:443", Connect).unwrap()
  assert_eq(connect.form, AuthorityForm)
  assert_eq(connect.authority.unwrap().host, "2001:db8::1")
  assert_eq(connect.validate(), Ok(()))
  assert_true(
    @types.Uri::parse_request_target("example.test", Connect)
    is Err(InvalidRequestTarget),
  )
  assert_eq(
    @types.Uri::parse_request_target("*", Options).unwrap().form,
    AsteriskForm,
  )
  assert_true(
    @types.Uri::parse_request_target("*", Get) is Err(InvalidRequestTarget),
  )
  assert_true(
    @types.Uri::parse_request_target("/", Connect) is Err(InvalidAuthority(_)),
  )
  assert_true(
    @types.Uri::parse_request_target("http://user@example.test/", Get)
    is Err(UserinfoNotAllowed),
  )
  assert_true(
    @types.Uri::parse_request_target("http:path", Get)
    is Err(InvalidRequestTarget),
  )
}

///|
test "types: URI and authority reject ambiguous or malformed octets" {
  for
    value in ["/bad%", "/bad%0", "/bad%xx", "/back\\slash", "/snowman-\u{2603}"] {
    assert_true(@types.Uri::parse(value) is Err(_))
  }
  for
    value in [
      "", "example.test:", "a:b:c", "[::1", "host:65536", "[not-an-ip]", "[gggg::1]",
      "[2001:db8::1:2:3:4:5:6:7:8]", "[v1]", "[v1.]", "[v1.g%]",
    ] {
    assert_true(@types.Authority::parse(value) is Err(_))
  }
  let ipv4_mapped = @types.Authority::parse("[::ffff:192.0.2.1]:443").unwrap()
  assert_eq(ipv4_mapped.host, "::ffff:192.0.2.1")
  let ipvfuture = @types.Authority::parse("[v1.fe80::]:443").unwrap()
  assert_eq(ipvfuture.host, "v1.fe80::")
  assert_eq(
    @types.Authority::parse_endpoint("user@example.test"),
    Err(InvalidAuthority),
  )
}

///|
test "types: resource defaults are finite and checked" {
  let limits = @types.Limits::defaults()
  assert_eq(limits.validate(), Ok(()))
  assert_true(limits.max_streams > 0)
  assert_true(limits.max_concurrent_requests > 0)
  assert_true(limits.max_dynamic_table_bytes >= 0)
  assert_true(limits.max_datagram_bytes > 0)
  assert_true(@types.Limits::new(max_body_bytes=-1) is Err(InvalidLimit(..)))
  assert_true(
    @types.Limits::new(max_header_line=100, max_header_bytes=99)
    is Err(InvalidLimit(field="max_header_line", ..)),
  )
}

///|
test "types: response body rules" {
  assert_eq(@types.response_allows_body(Get, 200), true)
  assert_eq(@types.response_allows_body(Head, 200), false)
  assert_eq(@types.response_allows_body(Get, 204), false)
  assert_eq(@types.response_allows_body(Connect, 200), false)
}
