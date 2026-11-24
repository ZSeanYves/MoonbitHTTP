///|
async fn unused_udp_endpoint() -> @types.Endpoint {
  let reservation = @socket.UdpServer(Addr(@socket.IpAddr::v4(0x7f000001U), 0))
  let endpoint = @types.Endpoint::new(
    "udp",
    "127.0.0.1",
    reservation.addr.port.to_int(),
  ).unwrap()
  reservation.close()
  endpoint
}

///|
struct UdpPeerPolicy {
  mut allow_peer : Bool
}

///|
impl @transport_api.NetworkPolicy for UdpPeerPolicy with fn authorize(
  self,
  _endpoint,
  operation,
) {
  if operation == Listen || self.allow_peer {
    Ok(())
  } else {
    Err(Denied(operation, "UDP peer rejected"))
  }
}

///|
async test "native UDP server: loopback retains source and authorizes every peer operation" {
  let endpoint = unused_udp_endpoint()
  let policy = UdpPeerPolicy::{ allow_peer: true, }
  let server = @transport.UdpServerSocket::bind(endpoint, policy).unwrap()
  defer server.close()
  let client = @transport.UdpSocket::connect(
    endpoint,
    @transport_api.AllowAllPolicy::new(),
  ).unwrap()
  defer client.close()
  @async.with_timeout(5000, async fn() {
    client.send(endpoint, b"request").unwrap()
    let request = server.receive(64).unwrap()
    assert_eq(request.payload(), b"request")
    assert_eq(request.endpoint().host(), "127.0.0.1")
    assert_true(request.endpoint().port() > 0)
    server.send(request.endpoint(), b"response").unwrap()
    assert_eq(client.receive(64).unwrap().payload(), b"response")
    policy.allow_peer = false
    assert_true(
      server.send(request.endpoint(), b"denied")
      is Err(Policy(Denied(QuicEndpoint, _))),
    )
    client.send(endpoint, b"denied").unwrap()
    assert_true(server.receive(64) is Err(Policy(Denied(QuicEndpoint, _))))
  })
  server.close()
  assert_true(server.receive(64) is Err(Closed))
  assert_true(server.send(endpoint, b"closed") is Err(Closed))
}

///|
async test "native UDP: server and connected socket reject oversized datagrams" {
  let endpoint = unused_udp_endpoint()
  let server = @transport.UdpServerSocket::bind(
    endpoint,
    @transport_api.AllowAllPolicy::new(),
  ).unwrap()
  defer server.close()
  let client = @transport.UdpSocket::connect(
    endpoint,
    @transport_api.AllowAllPolicy::new(),
  ).unwrap()
  defer client.close()
  @async.with_timeout(5000, async fn() {
    client.send(endpoint, b"peer").unwrap()
    let peer = server.receive(64).unwrap().endpoint()
    client.send(endpoint, b"12345").unwrap()
    assert_true(server.receive(4) is Err(InvalidDatagramSize))
    server.send(peer, b"12345").unwrap()
    assert_true(client.receive(4) is Err(InvalidDatagramSize))
  })
}
