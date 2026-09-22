///|
async test "client http1 round trip: informational, chunked body, and trailers" {
  let endpoint = @transport.Endpoint::new("http", "example.test", 80).unwrap()
  let response_bytes = b"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTrailer: X-Checksum\r\n\r\n3\r\nabc\r\n0\r\nX-Checksum: ok\r\n\r\n"
  let mut read_index = 0
  let writes : Array[Bytes] = []
  let connection = @transport.StreamConnection::new(
    endpoint,
    fn(max_bytes) {
      if read_index >= response_bytes.length() {
        return Ok(None)
      }
      let end = (read_index + max_bytes.min(7)).min(response_bytes.length())
      let value = response_bytes[read_index:end].to_owned()
      read_index = end
      Ok(Some(value))
    },
    fn(bytes) {
      writes.push(bytes)
      Ok(())
    },
    fn() { () },
  )
  let executor = @client.Http1RoundTripper::new(fn(_endpoint, _options) {
    Ok(connection)
  }).unwrap()
  let request : @types.Request[Bytes] = {
    http_method: Get,
    uri: @types.Uri::parse("http://example.test/").unwrap(),
    version: Http11,
    headers: @types.HeaderMap::new(),
    body: b"",
  }
  let response = executor.execute(request).unwrap()
  assert_eq(response.status, 200)
  assert_eq(response.body, b"abc")
  assert_eq(
    response.headers.get_string("x-checksum").unwrap().to_string_lossy(),
    "ok",
  )
  assert_true(writes.length() >= 1)
  let wire = @utf8.decode(writes[0]) catch { _ => "" }
  assert_true(wire.contains("host: example.test:80"))
}

///|
async test "client http1 round trip: decoded body limit closes on overflow" {
  let endpoint = @transport.Endpoint::new("http", "example.test", 80).unwrap()
  let connection = @transport.StreamConnection::new(
    endpoint,
    fn(_) { Ok(Some(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nabcd")) },
    fn(_) { Ok(()) },
    fn() { () },
  )
  let limits : @types.Limits = {
    ..@types.Limits::defaults(),
    max_body_bytes: 3,
  }
  let executor = @client.Http1RoundTripper::new(
    fn(_endpoint, _options) { Ok(connection) },
    limits~,
  ).unwrap()
  let request : @types.Request[Bytes] = {
    http_method: Get,
    uri: @types.Uri::parse("http://example.test/").unwrap(),
    version: Http11,
    headers: @types.HeaderMap::new(),
    body: b"",
  }
  assert_true(executor.execute(request) is Err(ClientProtocol(_)))
}
