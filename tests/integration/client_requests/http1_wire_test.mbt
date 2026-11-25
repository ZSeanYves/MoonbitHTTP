///|
async test "client http1 round trip: informational, chunked body, and trailers" {
  let endpoint = @types.Endpoint::new("http", "192.0.2.1", 80).unwrap()
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
  let executor = @client.Http1PooledRoundTripper::new(
    fn(_endpoint, _options) { Ok(connection) },
    fn(_, _) { Err(Unsupported) },
    resolve=Some(fn(_, _) {
      Ok([@types.IpAddress::parse("192.0.2.1").unwrap()])
    }),
    authorize=fn(_, _) { Ok(()) },
    now_millis=fn() { 0L },
  ).unwrap()
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
  let endpoint = @types.Endpoint::new("http", "192.0.2.1", 80).unwrap()
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
  let executor = @client.Http1PooledRoundTripper::new(
    fn(_endpoint, _options) { Ok(connection) },
    fn(_, _) { Err(Unsupported) },
    resolve=Some(fn(_, _) {
      Ok([@types.IpAddress::parse("192.0.2.1").unwrap()])
    }),
    options={ ..@client.RequestOptions::defaults(), limits, },
    authorize=fn(_, _) { Ok(()) },
    now_millis=fn() { 0L },
  ).unwrap()
  let request : @types.Request[Bytes] = {
    http_method: Get,
    uri: @types.Uri::parse("http://example.test/").unwrap(),
    version: Http11,
    headers: @types.HeaderMap::new(),
    body: b"",
  }
  assert_true(executor.execute(request) is Err(ClientHttp1(_)))
}

///|
async test "HTTP/1 follows a POST with a GET at the normalized absolute Location" {
  let connector : FacadeTestConnector = {
    responses: [
      b"HTTP/1.1 303 See Other\r\nLocation: http://origin.test/docs/../form\r\nContent-Length: 0\r\n\r\n",
      b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
    ],
    response_index: 0,
    connect_hosts: [],
    writes: [],
    closes: 0,
  }
  let resolver = @transport.StaticResolver::new([
    ("origin.test", [@types.IpAddress::parse("192.0.2.10").unwrap()]),
  ])
  let pool = @client.Http1PooledRoundTripper::from_capabilities(
    connector,
    resolver,
    @transport.UnsupportedProvider::new(),
    @transport.AllowAllPolicy::new(),
    @test_support.FixedClock::new(0L, 0L),
    options={
      ..@client.RequestOptions::defaults(),
      redirect: @client.RedirectPolicy::limited().unwrap(),
    },
  ).unwrap()
  defer pool.close()
  @client.with_client(
    async fn(client) {
      let request = pooled_request(
        "http://origin.test/form",
        @types.HeaderMap::new(),
      )
      let response = send_bytes(client, { ..request, http_method: Post, })
      assert_eq(response.status, 200)
      assert_eq(response.body, b"ok")
      assert_eq(connector.writes.length(), 2)
      assert_true(
        @utf8.decode_lossy(connector.writes[0]).has_prefix(
          "POST /form HTTP/1.1\r\n",
        ),
      )
      assert_true(
        @utf8.decode_lossy(connector.writes[1]).has_prefix(
          "GET /form HTTP/1.1\r\n",
        ),
      )
    },
    version=Http11,
    exchange=async fn(req) {
      pool
      .execute_body(req)
      .unwrap_or_error()
      .map_body(body => @client.IncomingBody::wrap(body))
    },
    now_millis=() => 0L,
    wall_clock_seconds=() => 0L,
    authorize_redirect=(_, _) => Ok(()),
    options={
      ..@client.RequestOptions::defaults(),
      redirect: @client.RedirectPolicy::limited().unwrap(),
    },
  )
}
