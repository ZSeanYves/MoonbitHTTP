///|
fn pump_quic_tls(
  client_options : @transport.TlsOptions,
  server_options : @transport.TlsOptions,
) -> Result[(Bool, Bool, Int), @transport.TlsError] {
  let client = NativeQuicTlsProvider::new(allow_system_roots=false)
  let server = NativeQuicTlsProvider::new(server=true, allow_system_roots=false)
  defer {
    client.close()
    server.close()
  }
  let client_decoders = [
    @tls.QuicHandshakeDecoder::new(QuicInitial).unwrap(),
    @tls.QuicHandshakeDecoder::new(QuicHandshake).unwrap(),
    @tls.QuicHandshakeDecoder::new(QuicApplication).unwrap(),
  ]
  let server_decoders = [
    @tls.QuicHandshakeDecoder::new(QuicInitial).unwrap(),
    @tls.QuicHandshakeDecoder::new(QuicHandshake).unwrap(),
    @tls.QuicHandshakeDecoder::new(QuicApplication).unwrap(),
  ]
  let client_offsets = [0L, 0L, 0L]
  let server_offsets = [0L, 0L, 0L]
  let queue : Array[(Bool, @transport.QuicTlsEvent)] = []
  let client_events = match
    client.start({ ..client_options, alpn: ["h3"], }, b"\x0f\x01c") {
    Ok(events) => events
    Err(error) => return Err(error)
  }
  let server_events = match
    server.start({ ..server_options, alpn: ["h3"], }, b"\x0f\x01s\x00\x01o") {
    Ok(events) => events
    Err(error) => return Err(error)
  }
  for event in client_events {
    queue.push((true, event))
  }
  for event in server_events {
    queue.push((false, event))
  }
  let mut client_complete = false
  let mut server_complete = false
  let mut secrets = 0
  let mut steps = 0
  while !queue.is_empty() {
    steps += 1
    if steps > 256 {
      return Err(HandshakeFailed("test handshake event limit"))
    }
    let (to_server, event) = queue.remove(0)
    match event {
      TrafficSecret(_, _, _, secret) => {
        if secret.is_empty() {
          return Err(InvalidTrafficSecret)
        }
        secrets += 1
      }
      HandshakeComplete(alpn, params) => {
        if alpn != "h3" {
          return Err(HandshakeFailed("unexpected test ALPN"))
        }
        if to_server {
          if params != b"\x0f\x01s\x00\x01o" {
            return Err(HandshakeFailed("wrong server transport parameters"))
          }
          client_complete = true
        } else {
          if params != b"\x0f\x01c" {
            return Err(HandshakeFailed("wrong client transport parameters"))
          }
          server_complete = true
        }
      }
      HandshakeBytes(level, bytes) => {
        let index = match level {
          QuicInitial => 0
          QuicHandshake => 1
          QuicApplication => 2
        }
        let decoder = if to_server {
          server_decoders[index]
        } else {
          client_decoders[index]
        }
        let offsets = if to_server { server_offsets } else { client_offsets }
        // Real OpenSSL output is fed in one-byte fragments through the bounded
        // message layer; no fixture traffic secret or Finished is supplied.
        for byte in bytes {
          let messages = match
            decoder.feed(offsets[index], Bytes::from_array([byte])) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          offsets[index] += 1L
          for message in messages {
            let events = match
              (if to_server { server } else { client }).receive_handshake(
                message,
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            for event in events {
              queue.push((!to_server, event))
            }
          }
        }
      }
    }
  }
  Ok((client_complete, server_complete, secrets))
}

///|
async test "native QUIC TLS: OpenSSL raw handshake verifies certificates, h3 and transport parameters" {
  let (client, server) = fixture_options()
  let result = pump_quic_tls(client, server).unwrap()
  assert_true(result.0 && result.1)
  assert_eq(result.2, 8)
}

///|
async test "native QUIC TLS: wrong hostname and untrusted CA never complete" {
  let (client, server) = fixture_options()
  let other = fixture("other.cert.pem")
  for
    client in [
      { ..client, server_name: Some("wrong.test"), },
      { ..client, trust_anchors: Some(other), },
    ] {
    assert_true(pump_quic_tls(client, server) is Err(_))
  }
}
