///|
fn request(
  path : String,
  meth : @types.Method,
  data : Bytes,
) -> @types.Request[@body.FullBody] {
  {
    http_method: meth,
    uri: @types.Uri::parse(path).unwrap(),
    version: Http3,
    headers: @types.HeaderMap::new(),
    body: @body.FullBody::new(data),
  }
}

///|
fn echo_payload(seed : Int32) -> Bytes {
  Bytes::from_array(FixedArray::makei(4096, i => ((i + seed) % 251).to_byte()))
}

///|
async fn check_body(
  response : @types.Response[@body.BodyStream],
  expected : Bytes,
) -> Unit {
  let (body, _) = @body.collect(response.body, max_bytes=expected.length())
  guard response.version == Http3 && response.status == 200 && body == expected else {
    fail("HTTP/3 status, version or response bytes differed")
  }
}

///|
async fn main {
  let args = @env.args()
  if args is [_, "--peer-soak", address, authority, ca, seconds, workers] {
    run_peer_soak(
      address,
      authority,
      ca,
      @string.parse_int(seconds),
      @string.parse_int(workers),
    ) catch {
      @quic.QuicError::Tls(cause) => fail("QUIC TLS failure: \{Repr(cause)}")
      @quic.QuicError::ConnectionClosed(code, reason) =>
        fail("QUIC connection closed (\{code}): \{reason}")
      err => raise err
    }
    return
  }
  let cert = @fs.read_binary("adapter/native/tls/testdata/localhost.cert.pem")
  let options = {
    ..@transport.TlsOptions::for_quic("localhost"),
    trust_anchors: Some(cert),
  }
  match args {
    [_, "--peer-restart", marker] => {
      check_peer_restart(options, marker)
      return
    }
    [_] => ()
    _ =>
      fail(
        "usage: h3_smoke_client [--peer-restart READY_FILE | --peer-soak ADDRESS AUTHORITY CA_FILE SECONDS WORKERS]",
      )
  }
  let endpoint = @types.Endpoint::new("udp", "localhost", 18444).unwrap()
  let resolver = @transport_native.NativeResolver::new()
  let payload = echo_payload(0)
  @async.with_timeout(20000, async fn() {
    @native_client.with_http3_pool(
      resolver,
      @transport.AllowAllPolicy::new(),
      tls=options,
      async fn(client) {
        let foreign = request("https://other.test/echo", Post, payload)
        let rejected = try {
          ignore(client.send(foreign))
          false
        } catch {
          @service.H3ClientError::InvalidOrigin => true
          error => raise error
        }
        guard rejected else {
          fail("client sent a request to a different HTTPS origin")
        }
        @async.with_task_group(async fn(group) {
          let echo = group.spawn(async fn() {
            let response = client.send(
              request("https://localhost:18444/echo", Post, payload),
            )
            check_body(response, payload)
          })
          let download = client.send(
            request("https://localhost:18444/131072", Get, b""),
          )
          check_body(download, Bytes::make(131072, b'Z'))
          echo.wait()
          assert_eq(client.connection_count(), 1)
        })
      },
    )
  })
  let wrong_name = { ..options, server_name: Some("wrong.test"), }
  @native_client.with_http3_client(
    endpoint,
    @transport.AllowAllPolicy::new(),
    wrong_name,
    resolver=Some(resolver),
    _ => fail("handshake callback accepted a mismatched identity"),
  ) catch {
    // OpenSSL X509_V_ERR_HOSTNAME_MISMATCH.
    @quic.QuicError::Tls(NativeFailure(Handshake, _, 62L, _)) => ()
    err => raise err
  }
  println(
    "PASS HTTP/3 client: verified concurrent 4096-byte POST echo, 131072-byte GET and certificate hostname rejection",
  )
}
