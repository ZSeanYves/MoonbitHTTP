///|
test "native listener preserves ordinary peer identity and rejects scoped IPv6" {
  for
    (address, expected_host) in [
      ("192.0.2.7:49152", "192.0.2.7"),
      ("[2001:db8::7]:49152", "2001:db8::7"),
      ("[::ffff:192.0.2.7]:49152", "::ffff:192.0.2.7"),
    ] {
    let endpoint = peer_endpoint(@socket.Addr::parse(address)).unwrap()
    assert_eq(endpoint.host(), expected_host)
    assert_eq(endpoint.port(), 49152)
  }
  for address in ["[fe80::7%1]:49152", "[fe80::7%999999]:49152"] {
    assert_true(
      peer_endpoint(@socket.Addr::parse(address))
      is Err(Policy(Denied(Accept, _))),
    )
  }
}
