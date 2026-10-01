///|
test "native HTTP/1 factory exposes bounded content decoding" {
  let client = new_http1_client(
    @transport_native.NativeResolver::new(),
    @transport.AllowAllPolicy::new(),
    @transport_native.NativeClock::new(),
    @tls_native.NativeTlsProvider::new(),
    content_decoding=true,
  ).unwrap()
  assert_true(client.content_decoding())
  assert_eq(
    client.content_coding_limits(),
    @content_coding.ContentCodingLimits::defaults(),
  )
  client.close()
}

///|
test "native HTTP/1 factory rejects invalid decoding limits" {
  let limits : @content_coding.ContentCodingLimits = {
    ..@content_coding.ContentCodingLimits::defaults(),
    max_decoded_bytes: -1,
  }
  let result = new_http1_client(
    @transport_native.NativeResolver::new(),
    @transport.AllowAllPolicy::new(),
    @transport_native.NativeClock::new(),
    @tls_native.NativeTlsProvider::new(),
    content_coding_limits=limits,
  )
  assert_true(result is Err(ClientInvalidOptions(_)))
}
