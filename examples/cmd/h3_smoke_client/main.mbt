///|
fn fields(verb : String, path : String) -> Array[@http3.QpackField] {
  [
    (":method", verb),
    (":scheme", "https"),
    (":authority", "localhost:18444"),
    (":path", path),
  ].map(pair => @http3.QpackField::from_strings(pair.0, pair.1).unwrap())
}

///|
fn[T, E : Error] checked(value : Result[T, E]) -> T raise E {
  match value {
    Ok(v) => v
    Err(e) => raise e
  }
}

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
    @native_client.with_http3_connection(
      endpoint,
      @transport.AllowAllPolicy::new(),
      options,
      async fn(io) {
        let post = checked(io.session.start_request(fields("POST", "/echo")))
        let get = checked(
          io.session.start_request(fields("GET", "/131072"), fin=true),
        )
        checked(io.session.send_data(post, payload, fin=true))
        let finished : Set[Int64] = Set([])
        let status_ok : Set[Int64] = Set([])
        let sizes : Map[Int64, Int] = Map([(post, 0), (get, 0)])
        while finished.length() < 2 {
          for action in io.next_events() {
            match action {
              Message(H3HeadersReceived(id, headers, false, false)) =>
                if headers.any(f => f.name == ":status" && f.value == b"200") {
                  status_ok.add(id)
                }
              Message(H3DataReceived(id, chunk)) => {
                guard sizes.get(id) is Some(offset) else {
                  fail("unexpected response stream")
                }
                if id == post {
                  guard chunk.length() <= payload.length() - offset &&
                    chunk[:] == payload[offset:offset + chunk.length()] else {
                    fail("echo mismatch")
                  }
                } else {
                  guard chunk.length() <= 131072 - offset else {
                    fail("oversized response")
                  }
                  for byte in chunk {
                    if byte != b'Z' {
                      fail("response data mismatch")
                    }
                  }
                }
                sizes[id] = offset + chunk.length()
              }
              Message(H3MessageFinished(id)) => {
                guard status_ok.contains(id) &&
                  sizes.get(id) ==
                  Some(if id == post { payload.length() } else { 131072 }) else {
                  fail("status or response length mismatch")
                }
                finished.add(id)
              }
              StreamFailed(_, _)
              | Transport(StreamReset(_, _) | SendStopped(_, _)) =>
                fail("request stream failed")
              _ => ()
            }
          }
        }
      },
    )
  })
  let wrong_name = { ..options, server_name: Some("wrong.test"), }
  @native_client.with_http3_connection(
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
