///|
async test "native TCP: hostname requires explicit resolution" {
  let endpoint = @types.Endpoint::new("http", "localhost", 80).unwrap()
  assert_true(
    @transport_api.StreamConnector::connect(
      @transport.TcpConnector::new(),
      endpoint,
      @transport_api.ConnectOptions::defaults(),
    )
    is Err(Failed(Resolve, "TCP requires a numeric endpoint")),
  )
}

///|
async test "native UDP: policy rejection precedes endpoint and socket setup" {
  // A hostname is not a usable UDP socket address. The policy error must win,
  // proving denial happens before the socket-address and socket setup paths.
  let endpoint = @types.Endpoint::new("udp", "example.test", 443).unwrap()
  assert_true(
    @transport.UdpSocket::connect(endpoint, @transport_api.DenyAllPolicy::new())
    is Err(Policy(Denied(QuicEndpoint, "network policy denied operation"))),
  )
  assert_true(
    @transport.UdpSocket::connect(
      endpoint,
      @transport_api.AllowAllPolicy::new(),
    )
    is Err(Failed(Resolve, "UDP requires a numeric endpoint")),
  )
}

///|
async test "native UDP: multicast is rejected after policy and before socket setup" {
  for
    host in [
      "224.0.0.1", "239.255.255.255", "ff02::1", "FF0E:0:0:0:0:0:0:1", "::ffff:224.0.0.1",
      "0:0:0:0:0:ffff:e000:1", "::FFFF:239.255.255.255",
    ] {
    let endpoint = @types.Endpoint::new("udp", host, 443).unwrap()
    assert_true(
      @transport.UdpSocket::connect(
        endpoint,
        @transport_api.DenyAllPolicy::new(),
      )
      is Err(Policy(Denied(QuicEndpoint, _))),
    )
    assert_true(
      @transport.UdpSocket::connect(
        endpoint,
        @transport_api.AllowAllPolicy::new(),
      )
      is Err(Failed(Connect, "connected UDP requires a unicast endpoint")),
    )
  }
}
