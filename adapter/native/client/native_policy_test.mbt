///|
async test "native HTTP/1 factory honors an explicit network policy" {
  let client = @client.new_http1_client(
    @transport_native.NativeResolver::new(),
    @transport.DenyAllPolicy::new(),
    @transport_native.NativeClock::new(),
    @tls_native.NativeTlsProvider::new(),
  ).unwrap()
  let request : @types.Request[Bytes] = {
    http_method: Get,
    uri: @types.Uri::parse("http://example.test/").unwrap(),
    version: Http11,
    headers: @types.HeaderMap::new(),
    body: b"",
  }
  assert_true(client.send(request) is Err(ClientPolicy(_)))
  client.close()
}

///|
async test "native HTTP/3 scope: handshake timeout releases the pending UDP receive" {
  let silent = @socket.UdpServer(@socket.Addr::new(0x7f000001U, 0))
  defer silent.close()
  let endpoint = @types.Endpoint::new("udp", "127.0.0.1", silent.addr.port()).unwrap()
  let mut called = false
  let timed_out = try {
    @client.with_http3_connection(
      endpoint,
      @transport.AllowAllPolicy::new(),
      @transport.TlsOptions::for_quic("localhost"),
      _ => called = true,
      handshake_timeout_ms=40,
    )
    false
  } catch {
    @async.TimeoutError => true
    err => raise err
  }
  assert_true(timed_out)
  assert_false(called)
}

///|
async test "HTTP/3 hostname policy stops a forbidden lookup before DNS" {
  let endpoint = @types.Endpoint::new("udp", "origin.test", 443).unwrap()
  let resolver = @transport.StaticResolver::new([])
  try
    @client.with_http3_client(
      endpoint,
      @transport.DenyAllPolicy::new(),
      @transport.TlsOptions::for_quic("origin.test"),
      _ => (fail("denied lookup reached the callback") : Unit),
      resolver=Some(resolver),
    )
  catch {
    @transport.TransportError::Policy(Denied(Resolve, _)) => ()
    error => raise error
  } noraise {
    _ => fail("lookup succeeded")
  }
}

///|
async test "HTTP/3 tries the next UDP address after a silent handshake" {
  let silent = @socket.UdpServer(@socket.Addr::new(0x7f000001U, 0))
  defer silent.close()
  let endpoint = @types.Endpoint::new("udp", "route.test", silent.addr.port()).unwrap()
  let resolver = @transport.StaticResolver::new([
    (
      "route.test",
      [
        @types.IpAddress::parse("127.0.0.1").unwrap(),
        @types.IpAddress::parse("224.0.0.1").unwrap(),
      ],
    ),
  ])
  try
    @client.with_http3_client(
      endpoint,
      @transport.AllowAllPolicy::new(),
      @transport.TlsOptions::for_quic("localhost"),
      _ => (fail("no authenticated peer") : Unit),
      resolver=Some(resolver),
      handshake_timeout_ms=1000,
    )
  catch {
    @transport.TransportError::Failed(
      Connect,
      "connected UDP requires a unicast endpoint"
    ) => ()
    error => raise error
  } noraise {
    _ => fail("unexpected handshake")
  }
  let bytes = FixedArray::make(2048, b'\x00')
  let (count, _) = @async.with_timeout(1000, async fn() {
    silent.recvfrom(bytes)
  })
  assert_true(count >= 1200)
}

///|
async test "a partial HTTP/1 response survives the continue timeout on a pooled TCP connection" {
  let listener = @socket.TcpServer(@socket.Addr::new(0x7f000001U, 0))
  defer listener.close()
  let client = @client.new_http1_client(
    @transport_native.NativeResolver::new(),
    @transport.AllowAllPolicy::new(),
    @transport_native.NativeClock::new(),
    @tls_native.NativeTlsProvider::new(),
    options={
      ..@client_api.RequestOptions::defaults(),
      timeouts: {
        ..@client_api.ClientTimeouts::defaults(),
        response_headers_ms: Some(250),
      },
    },
  ).unwrap()
  defer client.close()
  @async.with_timeout(5000, async fn() {
    @async.with_task_group(async fn(group) {
      group.spawn_bg(async fn() {
        let (peer, _) = listener.accept()
        defer peer.close()
        let head = peer.read_until("\r\n\r\n").unwrap()
        assert_true(head.contains("expect: 100-continue"))
        peer.write(b"HTTP/1.1 103 Early Hints\r\n\r\nHTTP/1.")
        assert_eq(peer.read_exactly(4), b"data")
        peer.write(b"1 200 OK\r\ncontent-length: 3\r\n\r\nyes")
        assert_true(peer.read_until("\r\n\r\n").unwrap().has_prefix("GET / "))
        peer.write(b"HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
      })
      let headers = @types.HeaderMap::new()
      headers.append_string("expect", "100-continue").unwrap()
      let request : @types.Request[Bytes] = {
        http_method: Post,
        version: Http11,
        headers,
        uri: @types.Uri::parse("http://" + listener.addr.to_string() + "/").unwrap(),
        body: b"data",
      }
      let response = client.send(request).unwrap()
      assert_eq(response.status, 200)
      assert_eq(response.body, b"yes")
      assert_eq(client.idle_connection_count(), 1)
      let next = client
        .send({
          ..request,
          http_method: Get,
          headers: @types.HeaderMap::new(),
          body: b"",
        })
        .unwrap()
      assert_eq(next.status, 204)
      assert_eq(client.connection_count(), 0)
    })
  })
}
