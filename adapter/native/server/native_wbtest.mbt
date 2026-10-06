///|
async test "native listener rejects hostname binds before touching the host socket" {
  let endpoint = @types.Endpoint::new("tcp", "localhost", 8080).unwrap()
  let result = NativeTcpListener::bind(
    endpoint,
    @transport.AllowAllPolicy::new(),
    async fn(_ : @transport.StreamConnection) -> Result[Unit, Error] {
      @async.sleep(0)
      Ok(())
    },
  )
  assert_true(result is Err(InvalidConfig(_)))
}

///|
async test "native listener rejects non-tcp schemes" {
  let endpoint = @types.Endpoint::new("udp", "127.0.0.1", 8080).unwrap()
  let result = NativeTcpListener::bind(
    endpoint,
    @transport.AllowAllPolicy::new(),
    async fn(_ : @transport.StreamConnection) -> Result[Unit, Error] {
      @async.sleep(0)
      Ok(())
    },
  )
  assert_true(result is Err(InvalidConfig(_)))
}

///|
async test "native listener policy rejects bind before creating socket" {
  let endpoint = @types.Endpoint::new("tcp", "127.0.0.1", 1).unwrap()
  let result = NativeTcpListener::bind(
    endpoint,
    @transport.DenyAllPolicy::new(),
    fn(_) { Ok(()) },
  )
  assert_true(result is Err(Policy(Denied(Listen, _))))
}

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
