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
