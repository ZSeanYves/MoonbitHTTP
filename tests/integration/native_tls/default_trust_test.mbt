///|
async test "OpenSSL default trust is configurable and explicit anchors replace it" {
  let success = "Verified process-entry OpenSSL trust and explicit replacement"
  let ca = fixture("localhost.cert.pem")
  guard @env.get_env_var("MOON_HTTP_TEST_DEFAULT_TRUST") is Some("1") else {
    // OpenSSL and the host runtime may use separate C environments on Windows.
    // Supplying paths at process creation also matches a deployment's startup.
    let directory = @fs.tmpdir(prefix="moon-http-ca")
    defer @fs.remove(directory, recursive=true)
    let pem = directory + "/test-root.pem"
    @fs.write_binary(pem, ca)
    let result = @process.run(
      @env.args()[0][:],
      ["default_trust_test.mbt:0-1"],
      extra_env={
        "MOON_HTTP_TEST_DEFAULT_TRUST": "1",
        "SSL_CERT_FILE": pem,
        "SSL_CERT_DIR": directory,
      },
      stdout=Collect,
      stderr=Collect,
      accepted_exit_code=_ => true,
    )
    let output = result.stdout_text()
    guard result.exit_code == 0 && output.contains(success) else {
      fail("OpenSSL trust subprocess: \{output}\n\{result.stderr_text()}")
    }
    return
  }
  let (client, server) = fixture_options()
  async fn verify(roots : Bytes?, trusted : Bool) -> Unit {
    let (client_result, peer) = handshake_pair(
      { ..client, trust_anchors: roots, },
      server,
      allow_system_roots=true,
    )
    if peer is Ok(connection) {
      connection.close()
    }
    match client_result {
      Ok(connection) => {
        defer connection.close()
        assert_true(trusted && connection.is_authenticated())
      }
      Err(NativeFailure(Handshake, _, verification, _)) => {
        assert_false(trusted)
        assert_true(verification != 0L)
      }
      Err(other) => fail("unanticipated TLS failure: \{Repr(other)}")
    }
  }
  verify(None, true)
  verify(Some(fixture("other.cert.pem")), false)
  @fs.remove(@env.get_env_var("SSL_CERT_FILE").unwrap())
  verify(None, false)
  verify(Some(ca), true)
  println(success)
}
