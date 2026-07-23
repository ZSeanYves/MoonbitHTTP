///|
test "http1: fragmented chunked request with trailers and pipeline" {
  let decoder = RequestDecoder::new()
  assert_eq(
    decoder.feed(
      b"POST /a HTTP/1.1\r\nHost: e\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nte",
    ),
    Ok(()),
  )
  guard decoder.next() is Ok(Some(RequestHead(head))) else {
    fail("missing head")
  }
  assert_eq(head.uri.value, "/a")
  guard decoder.next() is Ok(Some(RequestData(first))) else {
    fail("missing first body fragment")
  }
  assert_eq(first, b"te")
  assert_eq(decoder.next() is Ok(None), true)
  assert_eq(
    decoder.feed(
      b"st\r\n0\r\nX-Sum: ok\r\n\r\nGET /b HTTP/1.1\r\nHost: e\r\n\r\n",
    ),
    Ok(()),
  )
  guard decoder.next() is Ok(Some(RequestData(second))) else {
    fail("missing second body fragment")
  }
  assert_eq(second, b"st")
  guard decoder.next() is Ok(Some(RequestTrailers(trailers))) else {
    fail("missing trailers")
  }
  assert_eq(trailers.get_string("x-sum").unwrap().to_string_lossy(), "ok")
  assert_eq(decoder.next() is Ok(Some(RequestEnd)), true)
  guard decoder.next() is Ok(Some(RequestHead(next))) else {
    fail("pipeline head lost")
  }
  assert_eq(next.uri.value, "/b")
  assert_eq(decoder.next() is Ok(Some(RequestEnd)), true)
}

///|
test "http1: rejects smuggling framing conflicts" {
  let decoder = RequestDecoder::new()
  assert_eq(
    decoder.feed(
      b"POST / HTTP/1.1\r\nHost: e\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n",
    ),
    Ok(()),
  )
  assert_eq(decoder.next() is Err(InvalidFraming(_)), true)

  let duplicate = RequestDecoder::new()
  assert_eq(
    duplicate.feed(
      b"POST / HTTP/1.1\r\nHost: e\r\nContent-Length: 4\r\nContent-Length: 5\r\n\r\n",
    ),
    Ok(()),
  )
  assert_eq(duplicate.next() is Err(InvalidFraming(_)), true)
}

///|
test "http1: response HEAD and 204 never expose body" {
  let head = ResponseDecoder::new(Head)
  assert_eq(
    head.feed(b"HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\nnext"),
    Ok(()),
  )
  assert_eq(head.next() is Ok(Some(ResponseHead(_))), true)
  assert_eq(head.next() is Ok(Some(ResponseEnd)), true)

  let no_content = ResponseDecoder::new(Get)
  assert_eq(no_content.feed(b"HTTP/1.1 204 No Content\r\n\r\n"), Ok(()))
  assert_eq(no_content.next() is Ok(Some(ResponseHead(_))), true)
  assert_eq(no_content.next() is Ok(Some(ResponseEnd)), true)
}

///|
test "http1: chunked encoder preserves repeated headers and trailers" {
  let headers = @types.HeaderMap::new()
  assert_eq(headers.append_string("set-cookie", "a=1"), Ok(()))
  assert_eq(headers.append_string("set-cookie", "b=2"), Ok(()))
  let request : @types.Request[Unit] = {
    http_method: Post,
    uri: @types.Uri::parse("/").unwrap(),
    version: Http11,
    headers,
    body: (),
  }
  let head = encode_request_head(request, Chunked).unwrap()
  let text = @utf8.decode(head) catch { _ => "" }
  assert_eq(text.contains("set-cookie: a=1\r\nset-cookie: b=2"), true)
  let trailers = @types.HeaderMap::new()
  assert_eq(trailers.append_string("x-sum", "ok"), Ok(()))
  assert_eq(encode_body_data(b"abc", Chunked).unwrap(), b"3\r\nabc\r\n")
  assert_eq(
    encode_body_end(Chunked, trailers~).unwrap(),
    b"0\r\nx-sum: ok\r\n\r\n",
  )
}
