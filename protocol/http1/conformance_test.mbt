///|
test "http1 conformance: content-length is strict decimal" {
  for value in ["+1", "1x", "2147483648"] {
    let decoder = @http1.RequestDecoder::new()
    decoder
    .feed(
      @utf8.encode(
        "POST / HTTP/1.1\r\nHost: example.test\r\nContent-Length: " +
        value +
        "\r\n\r\n",
      ),
    )
    .unwrap()
    assert_eq(decoder.next() is Err(InvalidFraming(_)), true)
  }
}

///|
test "http1 conformance: duplicate content-length accepts only identical values" {
  let accepted = @http1.RequestDecoder::new()
  accepted
  .feed(
    b"POST / HTTP/1.1\r\nHost: example.test\r\nContent-Length: 04\r\nContent-Length: 4\r\n\r\nbody",
  )
  .unwrap()
  assert_eq(accepted.next() is Ok(Some(RequestHead(_))), true)
  assert_eq(accepted.next() is Ok(Some(RequestData(b"body"))), true)
  assert_eq(accepted.next() is Ok(Some(RequestEnd)), true)

  let rejected = @http1.RequestDecoder::new()
  rejected
  .feed(
    b"POST / HTTP/1.1\r\nHost: example.test\r\nContent-Length: 4\r\nContent-Length: 5\r\n\r\nbody",
  )
  .unwrap()
  assert_eq(rejected.next() is Err(InvalidFraming(_)), true)
}

///|
test "http1 conformance: unsupported transfer coding cannot define a request body" {
  let decoder = @http1.RequestDecoder::new()
  decoder
  .feed(
    b"POST / HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: gzip\r\n\r\n",
  )
  .unwrap()
  assert_eq(decoder.next() is Err(InvalidFraming(_)), true)
}

///|
test "http1 conformance: malformed status code is rejected" {
  let decoder = @http1.ResponseDecoder::new(Get)
  decoder.feed(b"HTTP/1.1 +00 Bad\r\n\r\n").unwrap()
  assert_eq(decoder.next() is Err(InvalidStartLine(_)), true)
}

///|
test "http1 conformance: method tokens are case-sensitive" {
  let decoder = @http1.RequestDecoder::new()
  decoder.feed(b"get / HTTP/1.1\r\nHost: example.test\r\n\r\n").unwrap()
  guard decoder.next() is Ok(Some(RequestHead(request))) else {
    fail("lowercase extension method was rejected")
  }
  assert_eq(request.http_method, Extension("get"))
  let invalid = @http1.RequestDecoder::new()
  invalid.feed(b"GE\tT / HTTP/1.1\r\nHost: example.test\r\n\r\n").unwrap()
  assert_true(invalid.next() is Err(InvalidStartLine(_)))
}

///|
test "http1 conformance: duplicate Host is unrecoverable" {
  let decoder = @http1.RequestDecoder::new()
  decoder
  .feed(b"GET / HTTP/1.1\r\nHost: example.test\r\nHost: example.test\r\n\r\n")
  .unwrap()
  assert_true(decoder.next() is Err(InvalidHeader(_)))
}

///|
test "http1 conformance: decoder preserves the first terminal error" {
  let decoder = @http1.RequestDecoder::new()
  decoder
  .feed(
    b"GET / HTTP/1.1\r\nBad Header: x\r\n\r\nGET /ok HTTP/1.1\r\nHost: e\r\n\r\n",
  )
  .unwrap()
  guard decoder.next() is Err(first) else {
    fail("invalid header was accepted")
  }
  guard decoder.next() is Err(second) else {
    fail("request decoder did not preserve its terminal error")
  }
  assert_eq(second, first)
  assert_eq(decoder.feed(b"GET /late HTTP/1.1\r\nHost: e\r\n\r\n"), Err(first))

  let response = @http1.ResponseDecoder::new(Get)
  response.feed(b"HTTP/1.1 +00 Bad\r\n\r\nHTTP/1.1 200 OK\r\n\r\n").unwrap()
  guard response.next() is Err(first) else {
    fail("invalid status was accepted")
  }
  guard response.next() is Err(second) else {
    fail("response decoder did not preserve its terminal error")
  }
  assert_eq(second, first)
  assert_eq(response.feed(b"HTTP/1.1 200 OK\r\n\r\n"), Err(first))
}

///|
test "http1 conformance: encoders reject invalid constructed metadata" {
  let request : @types.Request[Unit] = {
    http_method: Extension("BAD METHOD"),
    uri: @types.Uri::parse("/").unwrap(),
    version: Http11,
    headers: @types.HeaderMap::new(),
    body: (),
  }
  assert_true(
    @http1.encode_request_head(request, NoBody) is Err(InvalidStartLine(_)),
  )
  let response : @types.Response[Unit] = {
    status: 99,
    version: Http11,
    headers: @types.HeaderMap::new(),
    body: (),
  }
  assert_true(
    @http1.encode_response_head(response, Get, NoBody)
    is Err(InvalidStartLine(_)),
  )
}

///|
test "http1 conformance: request-target form follows the method" {
  let connect = @http1.RequestDecoder::new()
  connect
  .feed(b"CONNECT example.test:443 HTTP/1.1\r\nHost: example.test:443\r\n\r\n")
  .unwrap()
  guard connect.next() is Ok(Some(RequestHead(request))) else {
    fail("valid CONNECT authority-form was rejected")
  }
  assert_eq(request.uri.form, AuthorityForm)
  let invalid_connect = @http1.RequestDecoder::new()
  invalid_connect
  .feed(b"CONNECT /tunnel HTTP/1.1\r\nHost: example.test\r\n\r\n")
  .unwrap()
  assert_true(invalid_connect.next() is Err(InvalidStartLine(_)))
  let invalid_star = @http1.RequestDecoder::new()
  invalid_star.feed(b"GET * HTTP/1.1\r\nHost: example.test\r\n\r\n").unwrap()
  assert_true(invalid_star.next() is Err(InvalidStartLine(_)))
  let options = @http1.RequestDecoder::new()
  options.feed(b"OPTIONS * HTTP/1.1\r\nHost: example.test\r\n\r\n").unwrap()
  assert_true(options.next() is Ok(Some(RequestHead(_))))
}

///|
test "http1 conformance: CONNECT encoding and response switch preserve bytes" {
  let headers = @types.HeaderMap::new()
  headers.append_string("host", "example.test:443").unwrap()
  let request : @types.Request[Unit] = {
    http_method: Connect,
    uri: @types.Uri::parse_request_target("example.test:443", Connect).unwrap(),
    version: Http11,
    headers,
    body: (),
  }
  assert_eq(
    @http1.encode_request_head(request, NoBody).unwrap(),
    b"CONNECT example.test:443 HTTP/1.1\r\nhost: example.test:443\r\n\r\n",
  )

  let decoder = @http1.ResponseDecoder::new(Connect)
  decoder
  .feed(
    b"HTTP/1.1 200 Connection Established\r\nContent-Length: 42\r\n\r\ntunneled-bytes",
  )
  .unwrap()
  assert_true(decoder.next() is Ok(Some(ResponseHead(_))))
  assert_true(decoder.next() is Ok(Some(ResponseEnd)))
  assert_eq(decoder.take_buffered(), b"tunneled-bytes")
}

///|
test "http1 conformance: outgoing framing fits the selected version and header fields" {
  let headers = @types.HeaderMap::new()
  headers.append_string("host", "example.test").unwrap()
  let request : @types.Request[Unit] = {
    http_method: Get,
    uri: @types.Uri::parse("/").unwrap(),
    version: Http11,
    headers,
    body: (),
  }
  assert_true(
    @http1.encode_request_head(request, ContentLength(-1))
    is Err(InvalidFraming(_)),
  )
  assert_true(
    @http1.encode_request_head({ ..request, version: Http10, }, Chunked)
    is Err(InvalidFraming(_)),
  )
  headers.append_string("content-length", "4").unwrap()
  assert_true(
    @http1.encode_request_head(request, NoBody) is Err(InvalidFraming(_)),
  )
}

///|
test "http1 conformance: HEAD and 304 round-trip representation metadata without consuming a body" {
  for (request_method, status) in [(@types.Method::Head, 200), (Get, 304)] {
    for
      (name, value) in [
        ("content-length", "42"),
        ("transfer-encoding", "gzip, chunked"),
      ] {
      let headers = @types.HeaderMap::new()
      headers.append_string(name, value).unwrap()
      let response : @types.Response[Unit] = {
        status,
        version: Http11,
        headers,
        body: (),
      }
      let wire = @http1.encode_response_head(response, request_method, NoBody).unwrap()
      let decoder = @http1.ResponseDecoder::new(request_method)
      decoder.feed(wire).unwrap()
      decoder.feed(b"next").unwrap()
      guard decoder.next() is Ok(Some(ResponseHead(head))) else {
        fail("expected response head")
      }
      assert_true(
        head.headers.get_all_string(name) is [field] &&
        field.to_string_lossy() == value,
      )
      assert_true(decoder.next() is Ok(Some(ResponseEnd)))
      assert_eq(decoder.take_buffered(), b"next")
      assert_true(
        @http1.encode_response_head(response, request_method, Chunked)
        is Err(InvalidFraming(_)),
      )
    }
  }
}
