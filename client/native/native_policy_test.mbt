///|
async test "native HTTP/1 factory honors an explicit network policy" {
  let client = @native.new_http1_client_with_policy(
    @transport.DenyAllPolicy::new(),
  ).unwrap()
  let request : @types.Request[Bytes] = {
    http_method: Get,
    uri: @types.Uri::parse("http://example.test/").unwrap(),
    version: Http11,
    headers: @types.HeaderMap::new(),
    body: b"",
  }
  assert_true(client.send(request) is Err(ClientPolicy(_)))
  client.close()
}
