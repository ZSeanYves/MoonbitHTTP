///|
async test "native listener rejects hostname binds before touching the host socket" {
  let endpoint = @transport.Endpoint::new("tcp", "localhost", 8080).unwrap()
  let result = NativeTcpListener::bind(endpoint, async fn(
    _ : @transport.StreamConnection,
  ) -> Result[Unit, Error] {
    @async.sleep(0)
    Ok(())
  })
  assert_true(result is Err(InvalidConfig(_)))
}

///|
async test "native listener rejects non-tcp schemes" {
  let endpoint = @transport.Endpoint::new("udp", "127.0.0.1", 8080).unwrap()
  let result = NativeTcpListener::bind(endpoint, async fn(
    _ : @transport.StreamConnection,
  ) -> Result[Unit, Error] {
    @async.sleep(0)
    Ok(())
  })
  assert_true(result is Err(InvalidConfig(_)))
}
