///|
async fn fixture(name : String) -> Bytes {
  let path = "adapter/native/tls/testdata/" + name
  @fs.read_file(path).binary()
}

///|
fn test_tcp_stream(
  tcp : @socket.Tcp,
  endpoint : @types.Endpoint,
) -> @transport.StreamConnection {
  @transport.StreamConnection::new(
    endpoint,
    async fn(size) { Ok(tcp.read_some(max_len=size)) },
    async fn(bytes) {
      tcp.write(bytes)
      Ok(())
    },
    fn() { tcp.close() },
  )
}

///|
async fn handshake_pair(
  client_options : @transport.TlsOptions,
  server_options : @transport.TlsOptions,
) -> (
  Result[@transport.SecureConnection, @transport.TlsError],
  Result[@transport.SecureConnection, @transport.TlsError],
) {
  let listener = @socket.TcpServer(@socket.Addr::new(0x7f000001U, 0))
  defer listener.close()
  let endpoint = @types.Endpoint::new("tcp", "127.0.0.1", listener.addr.port()).unwrap()
  let provider = NativeTlsProvider::new(allow_system_roots=false)
  @async.with_timeout(5000, async fn() {
    @async.with_task_group(async fn(group) {
      let server_task = group.spawn(async fn() {
        let (tcp, _) = listener.accept()
        provider.server_handshake(
          test_tcp_stream(tcp, endpoint),
          server_options,
        )
      })
      let tcp = @socket.Tcp::connect(listener.addr)
      let client_result = provider.client_handshake(
        test_tcp_stream(tcp, endpoint),
        client_options,
      )
      (client_result, server_task.wait())
    })
  })
}

///|
async fn fixture_options() -> (@transport.TlsOptions, @transport.TlsOptions) {
  let cert = fixture("localhost.cert.pem")
  let key = fixture("localhost.key.pem")
  let client : @transport.TlsOptions = {
    ..@transport.TlsOptions::defaults(),
    server_name: Some("localhost"),
    trust_anchors: Some(cert),
    alpn: ["h2", "http/1.1"],
  }
  let server : @transport.TlsOptions = {
    ..@transport.TlsOptions::defaults(),
    verify_peer: false,
    server_certificate: Some(cert),
    server_private_key: Some(key),
    alpn: ["h2", "http/1.1"],
  }
  (client, server)
}

///|
async fn assert_identity_failure(
  client_options : @transport.TlsOptions,
  server_options : @transport.TlsOptions,
) -> Unit {
  let (client, server) = handshake_pair(client_options, server_options)
  match client {
    Err(NativeFailure(Handshake, code, verification, message)) => {
      assert_true(code != 0UL)
      assert_true(verification != 0L)
      assert_false(message.is_empty())
    }
    Ok(connection) => {
      connection.close()
      fail("invalid certificate identity was accepted")
    }
    Err(error) =>
      fail("unexpected certificate identity failure: \{Repr(error)}")
  }
  match server {
    Ok(connection) => connection.close()
    Err(_) => ()
  }
}

///|
async test "native TLS: memory PEM credentials negotiate TLS13 ALPN and exchange socket data" {
  let (client_options, server_options) = fixture_options()
  let (client, server) = handshake_pair(client_options, server_options)
  let client = client.unwrap()
  let server = server.unwrap()
  defer {
    client.close()
    server.close()
  }
  assert_eq(client.version(), Tls13)
  assert_eq(client.alpn(), Some("h2"))
  assert_eq(server.alpn(), Some("h2"))
  assert_true(client.cipher_suite().has_prefix("TLS_"))
  assert_true(client.is_authenticated())
  assert_false(server.is_authenticated())
  client.write(b"hello").unwrap()
  assert_eq(server.read(16).unwrap(), Some(b"hello"))
  server.write(b"world").unwrap()
  assert_eq(client.read(16).unwrap(), Some(b"world"))
}

///|
async test "native TLS: verifies numeric IP SAN and negotiates h3 without claiming QUIC" {
  let (client, server) = fixture_options()
  let (client, server) = handshake_pair(
    { ..client, server_name: Some("127.0.0.1"), alpn: ["h3"], },
    { ..server, alpn: ["h3"], },
  )
  let client = client.unwrap()
  let server = server.unwrap()
  defer {
    client.close()
    server.close()
  }
  assert_eq(client.alpn(), Some("h3"))
  assert_eq(server.alpn(), Some("h3"))
  assert_true(client.is_authenticated())
}

///|
async test "native TLS: certificate identity, trust and expiry failures preserve verification codes" {
  let (client, server) = fixture_options()
  let other = fixture("other.cert.pem")
  let expired = fixture("expired.cert.pem")
  let expired_key = fixture("expired.key.pem")
  for
    (client, server, expected) in [
      ({ ..client, server_name: Some("wrong.test"), }, server, 62L),
      ({ ..client, trust_anchors: Some(other), }, server, 18L),
      (
        { ..client, trust_anchors: Some(expired), },
        {
          ..server,
          server_certificate: Some(expired),
          server_private_key: Some(expired_key),
        },
        10L,
      ),
    ] {
    let (client, server) = handshake_pair(client, server)
    match client {
      Err(NativeFailure(Handshake, code, verification, message)) => {
        assert_true(code != 0UL)
        assert_eq(verification, expected)
        assert_false(message.is_empty())
      }
      Ok(connection) => {
        connection.close()
        fail("invalid peer was accepted")
      }
      Err(error) => fail("unexpected certificate failure: \{Repr(error)}")
    }
    match server {
      Ok(connection) => connection.close()
      Err(_) => ()
    }
  }
}

///|
async test "native TLS: wildcard identity accepts one label and rejects the base domain" {
  let wildcard = fixture("wildcard.cert.pem")
  let wildcard_key = fixture("wildcard.key.pem")
  let (client_options, server_options) = fixture_options()
  let server_options = {
    ..server_options,
    server_certificate: Some(wildcard),
    server_private_key: Some(wildcard_key),
  }
  let client_options = {
    ..client_options,
    server_name: Some("api.example.test"),
    trust_anchors: Some(wildcard),
  }
  let (client, server) = handshake_pair(client_options, server_options)
  let client = client.unwrap()
  let server = server.unwrap()
  assert_eq(client.peer_identity(), Some("api.example.test"))
  assert_true(client.is_authenticated())
  client.close()
  server.close()

  let (client, server) = handshake_pair(
    { ..client_options, server_name: Some("example.test"), },
    server_options,
  )
  match client {
    Err(NativeFailure(Handshake, _, verification, _)) =>
      assert_eq(verification, 62L)
    Ok(connection) => {
      connection.close()
      fail("wildcard certificate matched its base domain")
    }
    Err(error) => fail("unexpected wildcard identity result: \{Repr(error)}")
  }
  match server {
    Ok(connection) => connection.close()
    Err(_) => ()
  }
}

///|
async test "native TLS: partial-label wildcard never authenticates a DNS identity" {
  let certificate = fixture("partial_wildcard.cert.pem")
  let key = fixture("partial_wildcard.key.pem")
  let (client, server) = fixture_options()
  assert_identity_failure(
    {
      ..client,
      trust_anchors: Some(certificate),
      server_name: Some("api1.example.test"),
    },
    {
      ..server,
      server_certificate: Some(certificate),
      server_private_key: Some(key),
    },
  )
}

///|
async test "native TLS: IPv6 SAN compares binary addresses and rejects a different address" {
  let certificate = fixture("ipv6.cert.pem")
  let key = fixture("ipv6.key.pem")
  let (client_options, server_options) = fixture_options()
  let client_options = {
    ..client_options,
    trust_anchors: Some(certificate),
    server_name: Some("0:0:0:0:0:0:0:1"),
  }
  let server_options = {
    ..server_options,
    server_certificate: Some(certificate),
    server_private_key: Some(key),
  }
  let (client, server) = handshake_pair(client_options, server_options)
  let client = client.unwrap()
  let server = server.unwrap()
  assert_true(client.is_authenticated())
  client.close()
  server.close()
  assert_identity_failure(
    { ..client_options, server_name: Some("::2"), },
    server_options,
  )
}

///|
async test "native TLS: SAN takes precedence over CN and wrong IP is rejected" {
  let san = fixture("san_precedence.cert.pem")
  let san_key = fixture("san_precedence.key.pem")
  let (client, server) = fixture_options()
  let server = {
    ..server,
    server_certificate: Some(san),
    server_private_key: Some(san_key),
  }
  assert_identity_failure(
    { ..client, server_name: Some("localhost"), trust_anchors: Some(san), },
    server,
  )
  let (accepted_client, accepted_server) = handshake_pair(
    {
      ..client,
      server_name: Some("identity.example.test"),
      trust_anchors: Some(san),
    },
    server,
  )
  accepted_client.unwrap().close()
  accepted_server.unwrap().close()

  let (client, server) = fixture_options()
  assert_identity_failure({ ..client, server_name: Some("127.0.0.2"), }, server)
}

///|
async test "native TLS: not-yet-valid and wrong EKU certificates are rejected" {
  let notyet = fixture("notyet.cert.pem")
  let notyet_key = fixture("notyet.key.pem")
  let eku = fixture("client_only.cert.pem")
  let eku_key = fixture("client_only.key.pem")
  let (client, server) = fixture_options()
  assert_identity_failure(
    { ..client, server_name: Some("notyet.test"), trust_anchors: Some(notyet), },
    {
      ..server,
      server_certificate: Some(notyet),
      server_private_key: Some(notyet_key),
    },
  )
  assert_identity_failure(
    { ..client, server_name: Some("eku.test"), trust_anchors: Some(eku), },
    {
      ..server,
      server_certificate: Some(eku),
      server_private_key: Some(eku_key),
    },
  )
}

///|
async test "native TLS: configured CRL rejects a revoked peer before authentication" {
  let root = fixture("localhost.cert.pem")
  let crl = fixture("revoked.crl.pem")
  let revoked = fixture("revoked.cert.pem")
  let revoked_key = fixture("revoked.key.pem")
  let (client, server) = fixture_options()
  let (client, server) = handshake_pair(
    {
      ..client,
      server_name: Some("revoked.test"),
      trust_anchors: Some(root),
      revocation_lists: Some(crl),
      require_crl: true,
    },
    {
      ..server,
      server_certificate: Some(revoked),
      server_private_key: Some(revoked_key),
    },
  )
  match client {
    Err(NativeFailure(Handshake, _, verification, _)) =>
      assert_eq(verification, 23L)
    Ok(connection) => {
      connection.close()
      fail("revoked certificate was accepted with CRL checking enabled")
    }
    Err(error) => fail("unexpected CRL result: \{Repr(error)}")
  }
  match server {
    Ok(connection) => connection.close()
    Err(_) => ()
  }
}

///|
async test "native TLS: required OCSP fails closed when the peer omits a staple" {
  let root = fixture("localhost.cert.pem")
  let revoked = fixture("revoked.cert.pem")
  let revoked_key = fixture("revoked.key.pem")
  let (client, server) = fixture_options()
  let (client, server) = handshake_pair(
    {
      ..client,
      server_name: Some("revoked.test"),
      trust_anchors: Some(root),
      require_ocsp: true,
    },
    {
      ..server,
      server_certificate: Some(revoked),
      server_private_key: Some(revoked_key),
    },
  )
  match client {
    Err(NativeFailure(Handshake, _, verification, _)) =>
      assert_eq(verification, 100L)
    Ok(connection) => {
      connection.close()
      fail("missing OCSP staple was accepted in required mode")
    }
    Err(error) => fail("unexpected OCSP result: \{Repr(error)}")
  }
  match server {
    Ok(connection) => connection.close()
    Err(_) => ()
  }
}

///|
async test "native TLS: stapled OCSP revoked status is cryptographically checked" {
  let root = fixture("localhost.cert.pem")
  let revoked = fixture("revoked.cert.pem")
  let revoked_key = fixture("revoked.key.pem")
  let response = fixture("revoked.ocsp.der")
  let (client, server) = fixture_options()
  let (client, server) = handshake_pair(
    {
      ..client,
      server_name: Some("revoked.test"),
      trust_anchors: Some(root),
      require_ocsp: true,
    },
    {
      ..server,
      server_certificate: Some(revoked),
      server_private_key: Some(revoked_key),
      ocsp_response: Some(response),
    },
  )
  match client {
    Err(NativeFailure(Handshake, _, verification, _)) =>
      assert_eq(verification, 23L)
    Ok(connection) => {
      connection.close()
      fail("revoked stapled OCSP response was accepted")
    }
    Err(error) => fail("unexpected stapled OCSP result: \{Repr(error)}")
  }
  match server {
    Ok(connection) => connection.close()
    Err(_) => ()
  }
}

///|
async test "native TLS: malformed required OCSP response fails closed" {
  let root = fixture("localhost.cert.pem")
  let (client, server) = fixture_options()
  let (client, server) = handshake_pair(
    { ..client, trust_anchors: Some(root), require_ocsp: true, },
    { ..server, ocsp_response: Some(b"not-an-ocsp-response"), },
  )
  assert_true(client is Err(NativeFailure(Handshake, _, _, _)))
  match server {
    Ok(connection) => connection.close()
    Err(_) => ()
  }
}

///|
async test "native TLS: wildcard never spans multiple labels" {
  let wildcard = fixture("wildcard.cert.pem")
  let wildcard_key = fixture("wildcard.key.pem")
  let (client, server) = fixture_options()
  assert_identity_failure(
    {
      ..client,
      server_name: Some("deep.api.example.test"),
      trust_anchors: Some(wildcard),
    },
    {
      ..server,
      server_certificate: Some(wildcard),
      server_private_key: Some(wildcard_key),
    },
  )
}

///|
async test "native TLS: complete intermediate chain succeeds and missing intermediate fails" {
  let root = fixture("chain_root.cert.pem")
  let leaf = fixture("chain_leaf.cert.pem")
  let leaf_key = fixture("chain_leaf.key.pem")
  let fullchain = fixture("chain_leaf.fullchain.pem")
  let (client, server) = fixture_options()
  let client = {
    ..client,
    server_name: Some("chain.test"),
    trust_anchors: Some(root),
  }
  let (accepted_client, accepted_server) = handshake_pair(client, {
    ..server,
    server_certificate: Some(fullchain),
    server_private_key: Some(leaf_key),
  })
  accepted_client.unwrap().close()
  accepted_server.unwrap().close()
  assert_identity_failure(client, {
    ..server,
    server_certificate: Some(leaf),
    server_private_key: Some(leaf_key),
  })
}

///|
async test "native TLS: mutual TLS requires and validates a client certificate" {
  let (client, server) = fixture_options()
  let cert = fixture("localhost.cert.pem")
  let key = fixture("localhost.key.pem")
  let server = { ..server, verify_peer: true, trust_anchors: Some(cert), }
  let (authenticated_client, authenticated_server) = handshake_pair(
    { ..client, client_certificate: Some(cert), client_private_key: Some(key), },
    server,
  )
  let authenticated_client = authenticated_client.unwrap()
  let authenticated_server = authenticated_server.unwrap()
  assert_true(authenticated_server.is_authenticated())
  authenticated_client.close()
  authenticated_server.close()
  let (client, server) = handshake_pair(client, server)
  match client {
    Ok(connection) => connection.close()
    Err(_) => ()
  }
  assert_true(server is Err(NativeFailure(Handshake, _, _, _)))
}

///|
async test "native TLS: TLS12 range and ALPN mismatch are enforced by OpenSSL" {
  let (client, server) = fixture_options()
  let tls12_client = { ..client, min_version: Tls12, max_version: Some(Tls12), }
  let tls12_server = { ..server, min_version: Tls12, max_version: Some(Tls12), }
  let (left, right) = handshake_pair(tls12_client, tls12_server)
  let left = left.unwrap()
  let right = right.unwrap()
  assert_eq(left.version(), Tls12)
  left.close()
  right.close()
  let (left, right) = handshake_pair({ ..client, alpn: ["h3"], }, {
    ..server,
    alpn: ["h2"],
  })
  assert_true(left is Err(_))
  assert_true(right is Err(NativeFailure(Handshake, _, _, _)))
  let (left, right) = handshake_pair(tls12_client, server)
  assert_true(left is Err(_))
  assert_true(right is Err(NativeFailure(Handshake, _, _, _)))
}

///|
async test "native TLS: bad PEM and mismatched credentials fail before stream I/O" {
  let (client, server) = fixture_options()
  let other_key = fixture("other.key.pem")
  let provider = NativeTlsProvider::new(allow_system_roots=false)
  let mut io_calls = 0
  let mut closes = 0
  let endpoint = @types.Endpoint::new("tcp", "127.0.0.1", 443).unwrap()
  for
    (options, is_server) in [
      ({ ..client, trust_anchors: Some(b"malformed PEM"), }, false),
      ({ ..server, server_private_key: Some(other_key), }, true),
      ({ ..client, trust_anchors: None, }, false),
    ] {
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
      fn() { closes += 1 },
    )
    let result = if is_server {
      provider.server_handshake(stream, options)
    } else {
      provider.client_handshake(stream, options)
    }
    assert_true(result is Err(NativeFailure(Configure, _, _, _)))
    assert_true(stream.is_closed())
  }
  assert_eq(io_calls, 0)
  assert_eq(closes, 3)
}

///|
async test "native TLS: abrupt EOF closes the connection and prevents reuse" {
  let (client_options, server_options) = fixture_options()
  let (client, server) = handshake_pair(client_options, server_options)
  let client = client.unwrap()
  let server = server.unwrap()
  defer {
    client.close()
    server.close()
  }
  server.close()
  @async.with_timeout(5000, async fn() {
    assert_true(client.read(32) is Err(Failed(Receive, _)))
  })
  assert_true(client.is_closed())
  assert_eq(client.read(32), Err(Closed))
  assert_eq(client.write(b"after close"), Err(Closed))
}

///|
test "native TLS: close is idempotent and native handles cannot be reused" {
  let ssl = openssl_new(
    false, false, false, 0x0304, 0, b"localhost", false, b"", b"", false, false,
    b"", b"", b"", b"\x02h2",
  )
  assert_true(ssl.ready())
  ssl.close()
  ssl.close()
  let count = Ref(123)
  assert_false(ssl.ready())
  assert_eq(ssl.handshake(), -1)
  assert_eq(ssl.feed(b"after close"), -1)
  assert_eq(ssl.drain(), b"")
  assert_eq(ssl.read(FixedArray::make(8, b'\x00'), count), -1)
  assert_eq(count.val, 0)
  assert_eq(ssl.write(b"after close", 0, 11, count), -1)
  assert_eq(ssl.version(), 0)
  assert_eq(ssl.cipher(), b"")
  assert_eq(ssl.alpn(), b"")
  assert_false(ssl.peer_authenticated())
}
