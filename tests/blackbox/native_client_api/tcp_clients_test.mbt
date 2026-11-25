///|
async test "native HTTP/1 factory exposes bounded content decoding" {
  @client.with_client(
    client => {
      assert_true(client.content_decoding())
      assert_eq(
        client.content_coding_limits(),
        @content_coding.ContentCodingLimits::defaults(),
      )
    },
    version=Http11,
    policy=@transport.AllowAllPolicy::new(),
    content_decoding=true,
  )
}

///|
async test "native HTTP/1 factory rejects invalid decoding limits" {
  let limits = {
    ..@content_coding.ContentCodingLimits::defaults(),
    max_decoded_bytes: -1,
  }
  @client.with_client(
    _ => (fail("invalid limits accepted") : Unit),
    version=Http11,
    policy=@transport.AllowAllPolicy::new(),
    content_coding_limits=limits,
  ) catch {
    @client_api.ClientError::ClientInvalidOptions(_) => ()
    err => raise err
  }
}
