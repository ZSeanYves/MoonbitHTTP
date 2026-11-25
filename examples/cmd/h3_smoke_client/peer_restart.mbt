///|
async fn check_peer_restart(
  options : @transport.TlsOptions,
  marker : String,
) -> Unit {
  let origin = "https://localhost:18448"
  @async.with_timeout(15000, async fn() {
    @native_client.with_http3_pool(
      @transport_native.NativeResolver::new(),
      @transport.AllowAllPolicy::new(),
      tls=options,
      max_connections=1,
      handshake_timeout_ms=Some(2500),
      async fn(client) {
        async fn ready() -> Unit {
          let response = client.send(request(origin + "/ready", Get, b""))
          let (bytes, _) = @body.collect(response.body, max_bytes=16)
          assert_eq(response.status, 200)
          assert_eq(bytes, b"ready")
        }
        async fn expect_reset(
          path : String,
          meth : @types.Method,
          bytes : Bytes,
        ) -> Unit {
          try {
            ignore(client.send(request(origin + path, meth, bytes)))
            fail("request completed on a lost connection")
          } catch {
            @quic.QuicError::ConnectionClosed(0L, "QUIC stateless reset") => ()
            error => raise error
          }
        }
        ready()
        @async.with_task_group(async fn(group) {
          let held = group.spawn(async fn() { expect_reset("/hold", Get, b"") })
          while !@fs.exists(marker) {
            @async.sleep(5)
          }
          expect_reset("/wake", Post, Bytes::make(512, b'x'))
          held.wait()
        })
        ready()
        assert_eq(client.connection_count(), 1)
      },
    )
  })
  println(
    "PASS HTTP/3 peer restart: both requests reported the reset and the same pool reconnected",
  )
}
