///|
async fn signed_ocsp(
  subject? : String = "revoked.cert.pem",
  status? : Int = 0,
  this_offset? : Int = -60,
  next_offset? : Int = 3600,
  omit_next? : Bool = false,
  corrupt_signature? : Bool = false,
) -> Bytes {
  let response = @revocation_test.test_ocsp(
    fixture(subject),
    fixture("localhost.cert.pem"),
    fixture("localhost.key.pem"),
    status,
    this_offset,
    next_offset,
    omit_next,
    corrupt_signature,
  )
  assert_false(
    response.is_empty(),
    msg="failed to construct signed OCSP fixture",
  )
  response
}

///|
async fn signed_crl(
  issuer? : String = "localhost",
  revoked? : String = "",
  this_offset? : Int = -60,
  next_offset? : Int = 3600,
) -> Bytes {
  let response = @revocation_test.test_crl(
    fixture(issuer + ".cert.pem"),
    fixture(issuer + ".key.pem"),
    if revoked.is_empty() {
      b""
    } else {
      fixture(revoked)
    },
    this_offset,
    next_offset,
  )
  assert_false(
    response.is_empty(),
    msg="failed to construct signed CRL fixture",
  )
  response
}

///|
async fn revocation_options() -> (@transport.TlsOptions, @transport.TlsOptions) {
  let (client, server) = fixture_options()
  (
    { ..client, server_name: Some("revoked.test"), },
    {
      ..server,
      server_certificate: Some(fixture("revoked.cert.pem")),
      server_private_key: Some(fixture("revoked.key.pem")),
    },
  )
}

///|
async fn assert_revocation_accepted(
  client_options : @transport.TlsOptions,
  server_options : @transport.TlsOptions,
) -> Unit {
  let (client, server) = handshake_pair(client_options, server_options)
  let client = client.unwrap()
  let server = server.unwrap()
  assert_true(client.is_authenticated())
  client.close()
  server.close()
  let complete = Ref(false)
  let result = pump_quic_tls(
    client_options,
    server_options,
    client_completion=complete,
  ).unwrap()
  assert_true(result.0 && result.1 && complete.val)
}

///|
async fn assert_revocation_rejected(
  client_options : @transport.TlsOptions,
  server_options : @transport.TlsOptions,
  expected : Int64,
  allow_omitted_staple? : Bool = false,
) -> Unit {
  let (client, server) = handshake_pair(client_options, server_options)
  match server {
    Ok(connection) => connection.close()
    Err(_) => ()
  }
  match client {
    Err(NativeFailure(Handshake, _, verification, _)) =>
      // On some OpenSSL builds a wrong-CertID staple is sent and reports 75;
      // on others the server omits it and the client reports 100. Both fail
      // closed, so this exception is enabled only for that fixture.
      assert_true(
        verification == expected ||
        (allow_omitted_staple && verification == 100L),
        msg="unexpected revocation verification code: expected \{expected}, got \{verification}",
      )
    Ok(connection) => {
      connection.close()
      fail("revocation failure was accepted by stream TLS")
    }
    Err(error) => fail("unexpected stream revocation error: \{Repr(error)}")
  }
  let complete = Ref(false)
  let result = pump_quic_tls(
    client_options,
    server_options,
    client_completion=complete,
  )
  assert_false(
    complete.val,
    msg="QUIC emitted HandshakeComplete before rejection",
  )
  match result {
    Err(NativeFailure(Handshake, _, verification, _)) =>
      assert_true(
        verification == expected ||
        (allow_omitted_staple && verification == 100L),
        msg="unexpected QUIC revocation verification code: expected \{expected}, got \{verification}",
      )
    other => fail("unexpected QUIC revocation result: \{Repr(other)}")
  }
}

///|
async test "native TLS and QUIC: fresh signed GOOD OCSP authenticates the peer" {
  let (client, server) = revocation_options()
  assert_revocation_accepted({ ..client, require_ocsp: true, }, {
    ..server,
    ocsp_response: Some(signed_ocsp()),
  })
}

///|
async test "native TLS and QUIC: OCSP freshness and status failures never authenticate" {
  let (client, server) = revocation_options()
  let client = { ..client, require_ocsp: true, }
  // Each response is genuinely signed at test time. The expired and future
  // windows are far outside the five-minute skew; the stale thisUpdate case
  // still has a future nextUpdate to exercise the independent seven-day cap.
  for
    (response, expected) in [
      (signed_ocsp(omit_next=true), 99L),
      (signed_ocsp(this_offset=-(8 * 24 * 60 * 60)), 99L),
      (signed_ocsp(this_offset=3600, next_offset=7200), 99L),
      (signed_ocsp(this_offset=-7200, next_offset=-3600), 99L),
      (signed_ocsp(status=1), 23L),
      (signed_ocsp(status=2), 75L),
      (signed_ocsp(corrupt_signature=true), 97L),
    ] {
    assert_revocation_rejected(
      client,
      { ..server, ocsp_response: Some(response), },
      expected,
    )
  }
  // OpenSSL versions differ on whether a valid but wrong-CertID response is
  // stapled. Accept either the response-not-covering-peer code (75) or the
  // missing-staple code (100), while requiring rejection in both cases.
  assert_revocation_rejected(
    client,
    {
      ..server,
      ocsp_response: Some(signed_ocsp(subject="localhost.cert.pem")),
    },
    75L,
    allow_omitted_staple=true,
  )
  // Some OpenSSL builds send the malformed DER and report 96; others decline
  // to staple it and report the missing-staple code 100. Both fail closed.
  assert_revocation_rejected(
    client,
    { ..server, ocsp_response: Some(b"not-an-ocsp-response"), },
    96L,
    allow_omitted_staple=true,
  )
  assert_revocation_rejected(client, server, 100L)
}

///|
async test "native TLS and QUIC: optional OCSP permits absence but rejects a bad staple" {
  let (client, server) = revocation_options()
  assert_revocation_accepted(client, server)
  assert_revocation_rejected(
    client,
    { ..server, ocsp_response: Some(signed_ocsp(omit_next=true)), },
    99L,
  )
}

///|
async test "native TLS and QUIC: signed CRLs accept good peers and reject revoked or stale lists" {
  let (client, server) = revocation_options()
  let client = { ..client, require_crl: true, }
  assert_revocation_accepted(
    { ..client, revocation_lists: Some(signed_crl()), },
    server,
  )
  for
    (crl, expected) in [
      (signed_crl(revoked="revoked.cert.pem"), 23L),
      (signed_crl(this_offset=-7200, next_offset=-3600), 12L),
      (signed_crl(this_offset=3600, next_offset=7200), 11L),
    ] {
    assert_revocation_rejected(
      { ..client, revocation_lists: Some(crl), },
      server,
      expected,
    )
  }
}

///|
fn crl_bundle(first : Bytes, second : Bytes) -> Bytes {
  let bytes : Array[Byte] = []
  for byte in first {
    bytes.push(byte)
  }
  for byte in second {
    bytes.push(byte)
  }
  Bytes::from_array(bytes)
}

///|
async test "native TLS and QUIC: CRL checking covers every verified chain certificate" {
  let (client, server) = fixture_options()
  let client = {
    ..client,
    server_name: Some("chain.test"),
    trust_anchors: Some(fixture("chain_root.cert.pem")),
    require_crl: true,
  }
  let server = {
    ..server,
    server_certificate: Some(fixture("chain_leaf.fullchain.pem")),
    server_private_key: Some(fixture("chain_leaf.key.pem")),
  }
  let root_crl = signed_crl(issuer="chain_root")
  let intermediate_crl = signed_crl(issuer="chain_intermediate")
  assert_revocation_accepted(
    {
      ..client,
      revocation_lists: Some(crl_bundle(intermediate_crl, root_crl)),
    },
    server,
  )
  for
    (crls, expected) in [
      (intermediate_crl, 3L),
      (
        crl_bundle(
          intermediate_crl,
          signed_crl(issuer="chain_root", revoked="chain_intermediate.cert.pem"),
        ),
        23L,
      ),
      (
        crl_bundle(
          signed_crl(issuer="chain_intermediate", revoked="chain_leaf.cert.pem"),
          root_crl,
        ),
        23L,
      ),
    ] {
    assert_revocation_rejected(
      { ..client, revocation_lists: Some(crls), },
      server,
      expected,
    )
  }
}

///|
async test "native TLS and QUIC: server role rejects required OCSP before I/O" {
  let (_, server) = fixture_options()
  let server = { ..server, verify_peer: true, require_ocsp: true, }
  assert_eq(server.validate_server(), Err(OcspRequiresClientRole))
  let mut io_calls = 0
  let endpoint = @types.Endpoint::new("tcp", "127.0.0.1", 443).unwrap()
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
  let provider = NativeTlsProvider::new(allow_system_roots=false)
  assert_true(
    provider.server_handshake(stream, server)
    is Err(InvalidOptions(OcspRequiresClientRole)),
  )
  assert_eq(io_calls, 0)
  let quic = NativeQuicTlsProvider::new(server=true, allow_system_roots=false)
  defer quic.close()
  assert_true(
    quic.start({ ..server, alpn: ["h3"], }, b"")
    is Err(InvalidOptions(OcspRequiresClientRole)),
  )
}
