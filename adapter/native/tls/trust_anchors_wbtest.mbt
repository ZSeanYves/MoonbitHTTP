///|
async test "native TLS: empty custom roots fail before I/O even when system roots are allowed" {
  let endpoint = @types.Endpoint::new("tcp", "127.0.0.1", 443).unwrap()
  let provider = NativeTlsProvider::new(allow_system_roots=true)
  let options = {
    ..@transport.TlsOptions::defaults().for_server_name("localhost"),
    trust_anchors: Some(b""),
  }
  let mut io_calls = 0
  let stream = @transport.StreamConnection::new(
    endpoint,
    fn(_) {
      io_calls += 1
      Ok(None)
    },
    fn(_) {
      io_calls += 1
      Ok(())
    },
    fn() { () },
  )
  defer stream.close()
  assert_true(
    provider.client_handshake(stream, options)
    is Err(InvalidOptions(EmptyTrustAnchors)),
  )
  assert_true(
    provider.server_handshake(stream, options)
    is Err(InvalidOptions(EmptyTrustAnchors)),
  )
  assert_eq(io_calls, 0)
}

///|
test "native QUIC TLS: empty custom roots fail in both roles before provider initialization" {
  let options = {
    ..@transport.TlsOptions::for_quic("localhost"),
    trust_anchors: Some(b""),
  }
  for server in [false, true] {
    let provider = NativeQuicTlsProvider::new(server~, allow_system_roots=true)
    defer provider.close()
    assert_true(
      provider.start(options, b"") is Err(InvalidOptions(EmptyTrustAnchors)),
    )
  }
}
