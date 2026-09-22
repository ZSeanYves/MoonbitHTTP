///|
fn native_test_push_u16(output : Array[Byte], value : Int) -> Unit {
  output.push(((value >> 8) & 0xff).to_byte())
  output.push((value & 0xff).to_byte())
}

///|
fn native_test_push_u24(output : Array[Byte], value : Int) -> Unit {
  output.push(((value >> 16) & 0xff).to_byte())
  output.push(((value >> 8) & 0xff).to_byte())
  output.push((value & 0xff).to_byte())
}

///|
fn native_test_server_hello(
  version : Int,
  cipher : Int,
  alpn : String?,
) -> Bytes {
  let extensions : Array[Byte] = []
  if version == 0x0304 {
    native_test_push_u16(extensions, 0x002b)
    native_test_push_u16(extensions, 2)
    native_test_push_u16(extensions, version)
  }
  match alpn {
    Some(protocol) => {
      let encoded = @utf8.encode(protocol)
      native_test_push_u16(extensions, 0x0010)
      native_test_push_u16(extensions, encoded.length() + 3)
      native_test_push_u16(extensions, encoded.length() + 1)
      extensions.push(encoded.length().to_byte())
      for byte in encoded {
        extensions.push(byte)
      }
    }
    None => ()
  }
  let body : Array[Byte] = []
  native_test_push_u16(body, 0x0303)
  for _ in 0..<32 {
    body.push(b'\x00')
  }
  body.push(b'\x00')
  native_test_push_u16(body, cipher)
  body.push(b'\x00')
  if !extensions.is_empty() {
    native_test_push_u16(body, extensions.length())
    body.append(extensions[:])
  }
  let handshake : Array[Byte] = [b'\x02']
  native_test_push_u24(handshake, body.length())
  handshake.append(body[:])
  let record : Array[Byte] = [b'\x16', b'\x03', b'\x03']
  native_test_push_u16(record, handshake.length())
  record.append(handshake[:])
  Bytes::from_array(record)
}

///|
test "native TLS: observes fragmented TLS 1.3 ServerHello metadata" {
  let wire = native_test_server_hello(0x0304, 0x1301, None)
  let observer = NativeTlsObserver::new()
  observer.feed(wire[:3].to_owned())
  assert_true(observer.result() is Err(_))
  observer.feed(wire[3:17].to_owned())
  assert_true(observer.result() is Err(_))
  observer.feed(wire[17:].to_owned())
  let metadata = observer.result().unwrap()
  assert_true(metadata.version == Tls13)
  assert_eq(metadata.cipher_suite, "TLS_AES_128_GCM_SHA256")
  assert_eq(metadata.alpn, None)
}

///|
test "native TLS: observes TLS 1.2 ALPN selection" {
  let wire = native_test_server_hello(0x0303, 0xc02f, Some("http/1.1"))
  let observer = NativeTlsObserver::new()
  observer.feed(wire)
  let metadata = observer.result().unwrap()
  assert_true(metadata.version == Tls12)
  assert_eq(metadata.cipher_suite, "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256")
  assert_eq(metadata.alpn, Some("http/1.1"))
}

///|
test "native TLS: rejects oversized records before allocation" {
  let observer = NativeTlsObserver::new()
  observer.feed(b"\x16\x03\x03\x48\x01")
  match observer.result() {
    Err(message) => assert_true(message.contains("record exceeded"))
    Ok(_) => fail("expected oversized TLS record to be rejected")
  }
}

///|
test "native TLS: version policy is enforced on observed result" {
  let defaults = @tls.TlsOptions::defaults()
  assert_true(!native_tls_version_allowed(defaults, Tls12))
  assert_true(native_tls_version_allowed(defaults, Tls13))
  let tls12 : @tls.TlsOptions = {
    ..defaults,
    min_version: Tls12,
    max_version: Some(Tls12),
  }
  assert_true(native_tls_version_allowed(tls12, Tls12))
  assert_true(!native_tls_version_allowed(tls12, Tls13))
}

///|
test "native TLS: ALPN options fail closed when host TLS cannot offer them" {
  let http1 : @tls.TlsOptions = {
    ..@tls.TlsOptions::defaults(),
    alpn: ["http/1.1"],
  }
  let h2 : @tls.TlsOptions = { ..http1, alpn: ["h2", "http/1.1"], }
  assert_true(native_tls_alpn_supported(http1))
  assert_true(!native_tls_alpn_supported(h2))
}

///|
async test "native TLS: unsupported credentials and server mode fail closed" {
  let endpoint = @transport.Endpoint::new("tcp", "127.0.0.1", 443).unwrap()
  let connection = @transport.StreamConnection::new(
    endpoint,
    async fn(_) {
      @async.pause()
      Ok(None)
    },
    async fn(_) {
      @async.pause()
      Ok(())
    },
    fn() {  },
  )
  let provider = NativeTlsProvider::new()
  let base : @tls.TlsOptions = {
    ..@tls.TlsOptions::defaults(),
    server_name: Some("example.test"),
    alpn: ["http/1.1"],
  }
  let custom_root : @tls.TlsOptions = {
    ..base,
    trust_anchors: Some(b"-----BEGIN CERTIFICATE-----"),
  }
  assert_true(
    provider.client_handshake(connection, custom_root) is Err(Unsupported),
  )
  let client_identity : @tls.TlsOptions = {
    ..base,
    client_certificate: Some(b"certificate"),
    client_private_key: Some(b"private-key"),
  }
  assert_true(
    provider.client_handshake(connection, client_identity) is Err(Unsupported),
  )
  let server_options : @tls.TlsOptions = {
    ..base,
    verify_peer: false,
    server_name: None,
  }
  assert_true(
    provider.server_handshake(connection, server_options) is Err(Unsupported),
  )
}
