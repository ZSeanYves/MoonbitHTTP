///|
async test "native HTTP/1 factory honors an explicit network policy" {
  @client.with_client(
    async fn(client) {
      let request = client.request(
        Get,
        @types.Uri::parse("http://example.test/").unwrap(),
        @client_api.Upload::bytes(b""),
      )
      try ignore(client.send(request)) catch {
        @client_api.ClientError::ClientPolicy(_) => ()
        err => raise err
      } noraise {
        _ => fail("denied request succeeded")
      }
    },
    version=Http11,
    policy=@transport.DenyAllPolicy::new(),
  )
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
