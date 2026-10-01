///|
async fn unused_tcp_endpoint() -> @types.Endpoint {
  let reservation = @socket.TcpServer(@socket.Addr::new(0x7f000001U, 0))
  let endpoint = @types.Endpoint::new(
    "tcp",
    "127.0.0.1",
    reservation.addr.port(),
  ).unwrap()
  reservation.close()
  endpoint
}

///|
async fn listener_tls_options() -> (
  @transport.TlsOptions,
  @transport.TlsOptions,
) {
  let certificate = @fs.read_file("tls/native/testdata/localhost.cert.pem").binary()
  let key = @fs.read_file("tls/native/testdata/localhost.key.pem").binary()
  (
    {
      ..@transport.TlsOptions::defaults(),
      server_name: Some("localhost"),
      trust_anchors: Some(certificate),
      alpn: ["http/1.1"],
    },
    {
      ..@transport.TlsOptions::defaults(),
      verify_peer: false,
      server_certificate: Some(certificate),
      server_private_key: Some(key),
      alpn: ["http/1.1"],
    },
  )
}

///|
async test "native TLS listener invokes secure handler only after authenticated handshake" {
  let (client_options, server_options) = listener_tls_options()
  let provider = @tls_native.NativeTlsProvider::new(allow_system_roots=false)
  let endpoint = unused_tcp_endpoint()
  let mut handled = false
  let listener = NativeTcpListener::bind_tls(
    endpoint,
    @transport.AllowAllPolicy::new(),
    provider,
    server_options,
    async fn(secure) {
      assert_eq(secure.alpn(), Some("http/1.1"))
      secure.write(b"secure").unwrap()
      handled = true
      Ok(())
    },
  ).unwrap()
  defer listener.close()
  @async.with_timeout(5000, async fn() {
    @async.with_task_group(async fn(group) {
      group.spawn_bg(async fn() {
        let accepted = listener.accept().unwrap().unwrap()
        match (accepted.run)() {
          Err(error) => raise error
          Ok(_) => ()
        }
      })
      let stream = @transport_native.TcpConnector::new()
        .connect(endpoint, @transport.ConnectOptions::defaults())
        .unwrap()
      let secure = provider.client_handshake(stream, client_options).unwrap()
      defer secure.close()
      assert_true(secure.is_authenticated())
      assert_eq(secure.read(32).unwrap(), Some(b"secure"))
    })
  })
  assert_true(handled)
}

///|
async test "native TLS listener timeout closes stalled peer without invoking handler" {
  let (_, server_options) = listener_tls_options()
  let endpoint = unused_tcp_endpoint()
  let mut handled = false
  let listener = NativeTcpListener::bind_tls(
    endpoint,
    @transport.AllowAllPolicy::new(),
    @tls_native.NativeTlsProvider::new(),
    server_options,
    fn(_) {
      handled = true
      Ok(())
    },
    handshake_timeout_ms=20,
  ).unwrap()
  defer listener.close()
  let stream = @transport_native.TcpConnector::new()
    .connect(endpoint, @transport.ConnectOptions::defaults())
    .unwrap()
  defer stream.close()
  let accepted = listener.accept().unwrap().unwrap()
  try (accepted.run)() catch {
    @async.TimeoutError => ()
    error => raise error
  } noraise {
    _ => fail("stalled TLS peer did not time out")
  }
  assert_false(handled)
  assert_eq(stream.read(32).unwrap(), None)
}

///|
struct DenyAcceptedPeer(Unit)

///|
impl @transport.NetworkPolicy for DenyAcceptedPeer with fn authorize(
  self,
  _endpoint,
  operation,
) {
  let DenyAcceptedPeer(_) = self
  if operation == Accept {
    Err(Denied(Accept, "peer rejected"))
  } else {
    Ok(())
  }
}

///|
async test "native listener authorizes accepted peer before exposing connection" {
  let endpoint = unused_tcp_endpoint()
  let listener = NativeTcpListener::bind(endpoint, DenyAcceptedPeer(()), fn(_) {
    Ok(())
  }).unwrap()
  defer listener.close()
  let stream = @transport_native.TcpConnector::new()
    .connect(endpoint, @transport.ConnectOptions::defaults())
    .unwrap()
  defer stream.close()
  assert_true(listener.accept() is Err(Policy(Denied(Accept, "peer rejected"))))
  assert_eq(stream.read(32).unwrap(), None)
}
