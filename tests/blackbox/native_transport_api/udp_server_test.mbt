///|
async test "native UDP server: policy denial precedes socket setup" {
  let hostname = @types.Endpoint::new("udp", "example.test", 443).unwrap()
  assert_true(
    @transport.UdpServerSocket::bind(
      hostname,
      @transport_api.DenyAllPolicy::new(),
    )
    is Err(Policy(Denied(Listen, _))),
  )
  assert_true(
    @transport.UdpServerSocket::bind(
      hostname,
      @transport_api.AllowAllPolicy::new(),
    )
    is Err(Failed(Resolve, _)),
  )
}
