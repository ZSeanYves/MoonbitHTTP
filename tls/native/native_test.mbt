///|
async test "native TLS public API requires explicit server credentials before I/O" {
  let mut reads = 0
  let mut writes = 0
  let endpoint = @types.Endpoint::new("tcp", "127.0.0.1", 443).unwrap()
  let stream = @transport.StreamConnection::new(
    endpoint,
    fn(_) {
      reads += 1
      Ok(None)
    },
    fn(_) {
      writes += 1
      Ok(())
    },
    fn() { () },
  )
  let result = @native.NativeTlsProvider::new().server_handshake(stream, {
    ..@transport.TlsOptions::defaults(),
    verify_peer: false,
  })
  assert_true(result is Err(InvalidOptions(IncompleteServerCertificate)))
  assert_eq(reads, 0)
  assert_eq(writes, 0)
  stream.close()
}
