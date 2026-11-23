///|
async fn main {
  let cert = @fs.read_file("adapter/native/tls/testdata/localhost.cert.pem").binary()
  let options = {
    ..@transport.TlsOptions::for_quic("localhost"),
    trust_anchors: Some(cert),
  }
  let endpoint = @types.Endpoint::new("udp", "127.0.0.1", 18444).unwrap()
  let payload = Bytes::from_array(
    FixedArray::makei(4096, i => (i % 251).to_byte()),
  )
  @async.with_timeout(20000, async fn() {
    @native_client.with_http3_client(
      endpoint,
      @transport.AllowAllPolicy::new(),
      options,
      async fn(client) {
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
            let response = client.send(request("/echo", Post, payload))
            let (body, _) = @body.collect(response.body, max_bytes=4096)
            guard response.version == Http3 &&
              response.status == 200 &&
              body == payload else {
              fail("echo mismatch")
            }
          })
          let download = client.send(
            request("https://localhost:18444/131072", Get, b""),
          )
          let (body, _) = @body.collect(download.body, max_bytes=131072)
          guard download.version == Http3 &&
            download.status == 200 &&
            body.length() == 131072 else {
            fail("invalid download")
          }
          for byte in body {
            if byte != b'Z' {
              fail("invalid download byte")
            }
          }
          echo.wait()
        })
      },
    )
  })
  let wrong_name = { ..options, server_name: Some("wrong.test"), }
  @native_client.with_http3_client(
    endpoint,
    @transport.AllowAllPolicy::new(),
    wrong_name,
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
