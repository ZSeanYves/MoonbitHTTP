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
