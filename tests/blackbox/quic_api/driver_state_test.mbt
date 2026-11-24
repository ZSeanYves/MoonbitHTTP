///|
test "QUIC driver honors the negotiated idle timeout" {
  let endpoint = @types.Endpoint::new("udp", "127.0.0.1", 443).unwrap()
  let server = @quic.ConnectionId::new(b"server-id").unwrap()
  let client = @quic.ConnectionId::new(b"client-id").unwrap()
  for
    (local_idle, remote_idle, expires) in [
      (30000L, 10000L, Some(10000L)),
      (10000L, 30000L, Some(10000L)),
      (0L, 10000L, Some(10000L)),
      (10000L, 0L, Some(10000L)),
      // Initial RTT 100ms, variance 50ms and peer max_ack_delay 25ms.
      (1L, 1L, Some(975L)),
      (0L, 0L, None),
    ] {
    let local_limits = {
      ..@quic.QuicTransportParams::defaults(),
      max_idle_timeout: local_idle,
    }
    let driver = @quic.QuicDatagramDriver::new(
      Server,
      endpoint,
      server,
      server,
      client,
      transport_params=local_limits,
      recovery_config={
        ..@quic.QuicRecoveryConfig::defaults(),
        initial_rtt_ms: 100L,
      },
    ).unwrap()
    let keys = @quic.quic_initial_packet_keys(server).unwrap()
    driver.install_handshake_keys(keys.1, keys.0).unwrap()
    driver.install_application_keys(keys.1, keys.0).unwrap()
    let limits = { ..local_limits, max_idle_timeout: remote_idle, }
    driver
    .set_peer_transport_parameters(
      @quic.QuicTransportParameters::new(client, limits~),
    )
    .unwrap()
    driver.establish().unwrap()
    if expires is Some(ms) {
      ignore(driver.poll(ms - 1L).unwrap())
      assert_eq(driver.state(), Established)
      ignore(driver.poll(ms).unwrap())
      assert_eq(driver.state(), Closed)
    } else {
      ignore(driver.poll(60000L).unwrap())
      assert_eq(driver.state(), Established)
    }
  }
}
