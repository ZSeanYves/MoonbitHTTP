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
async test "HTTP/3 hostname policy stops a forbidden lookup before DNS" {
  let endpoint = @types.Endpoint::new("udp", "origin.test", 443).unwrap()
  let resolver = @transport.StaticResolver::new([])
  try
    @client.with_http3_client_connection(
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
