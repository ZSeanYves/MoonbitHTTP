///|
test "native transport: numeric endpoints bypass hostname resolution" {
  let ipv4 = @types.Endpoint::new("http", "127.0.0.1", 80).unwrap()
  let ipv6 = @types.Endpoint::new("http", "::1", 80).unwrap()
  let hostname = @types.Endpoint::new("http", "localhost", 80).unwrap()
  assert_true(numeric_socket_addr(ipv4) is Some(_))
  assert_true(numeric_socket_addr(ipv6) is Some(_))
  assert_eq(numeric_socket_addr(hostname), None)
}

///|
test "native UDP: unicast classification includes IPv4-mapped IPv6" {
  for
    host in [
      "127.0.0.1", "223.255.255.255", "240.0.0.1", "::1", "2001:db8::1", "::ffff:127.0.0.1",
      "0:0:0:0:0:ffff:7f00:1",
    ] {
    let endpoint = @types.Endpoint::new("udp", host, 443).unwrap()
    assert_true(
      !udp_connected_is_multicast(numeric_socket_addr(endpoint).unwrap()),
    )
  }
}
