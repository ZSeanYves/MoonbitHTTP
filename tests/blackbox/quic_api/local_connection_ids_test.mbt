///|
test "a wide CID limit remains representable, while a zero-length local CID cannot rotate" {
  let peer = @quic.ConnectionId::new(b"server-id").unwrap()
  let client = @quic.QuicDatagramDriver::new(
    Client,
    @types.Endpoint::new("udp", "peer.test", 443).unwrap(),
    peer,
    @quic.ConnectionId::new(b"").unwrap(),
    peer,
    transport_params={
      ..@quic.QuicTransportParams::defaults(),
      active_connection_id_limit: 1L << 32,
    },
  ).unwrap()
  assert_true(
    client.enable_connection_id_issuance(@test_support.ZeroEntropy::new())
    is Err(InvalidPacket(_)),
  )
}
