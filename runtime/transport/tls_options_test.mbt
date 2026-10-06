///|
test "TLS options: explicit empty roots fail for both roles without changing default trust" {
  let defaults = @transport.TlsOptions::defaults()
  let client = defaults.for_server_name("example.com")
  assert_eq(client.validate_client(), Ok(()))
  assert_eq(defaults.validate_server(), Ok(()))
  for verify_peer in [true, false] {
    let options = { ..client, verify_peer, trust_anchors: Some(b""), }
    assert_eq(options.validate_client(), Err(EmptyTrustAnchors))
    assert_eq(options.validate_server(), Err(EmptyTrustAnchors))
  }
  let custom = { ..client, trust_anchors: Some(b"provider-validated PEM"), }
  assert_eq(custom.validate_client(), Ok(()))
  assert_eq(custom.validate_server(), Ok(()))
}
