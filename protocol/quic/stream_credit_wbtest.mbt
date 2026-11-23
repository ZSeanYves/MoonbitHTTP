///|
test "QUIC driver retains blocked credit and releases stream bytes on packet ACK" {
  let endpoint = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  let limits = {
    ..QuicLimits::defaults(),
    max_connection_data: 8L,
    max_stream_data: 8L,
  }
  let (client, server) = key_limit_driver_pair(endpoint, endpoint, limits~)
  let id = client.connection().open_bidirectional_stream().unwrap()
  guard client.send_stream(id, b"12345678", false, 0L).unwrap()
    is SendDatagram(_, packet) else {
    fail("expected stream packet")
  }
  let received = server.on_datagram(endpoint, packet, 1L).unwrap()
  assert_true(received.contains(StreamData(id, b"12345678", false)))
  assert_true(client.send_stream(id, b"x", false, 2L) is Err(FlowControl(_, _)))
  for action in received {
    if action is SendDatagram(_, ack) {
      ignore(client.on_datagram(endpoint, ack, 3L).unwrap())
    }
  }
  assert_eq(client.connection().retained_send_bytes, 0L)
  let connection = server.connection()
  connection.consume_stream_data(id, 8).unwrap()
  server.recovery.bytes_in_flight = server.recovery.congestion_window
  assert_eq(server.poll(4L).unwrap(), [])
  assert_eq(connection.credit_updates(2), [MaxData(16L)])
  assert_eq(connection.local_max_data, 8L)
  server.recovery.bytes_in_flight = 0L
  let grants = server.poll(5L).unwrap()
  for action in grants {
    if action is SendDatagram(_, credit) {
      ignore(client.on_datagram(endpoint, credit, 6L).unwrap())
    }
  }
  assert_eq(connection.local_max_data, 16L)
  assert_eq(connection.take_credit_updates(), [])
  guard client.send_stream(id, b"abcdefgh", false, 7L).unwrap()
    is SendDatagram(_, next) else {
    fail("expected second stream packet")
  }
  assert_true(
    server
    .on_datagram(endpoint, next, 8L)
    .unwrap()
    .contains(StreamData(id, b"abcdefgh", false)),
  )
}

///|
test "QUIC cumulative ACK preserves outstanding boundaries and untouched tail" {
  let sent : SentStreamRanges = { ranges: [], bytes: 0L, }
  sent.append(0L, 40L)
  for start in [4L, 12L, 20L, 28L] {
    assert_eq(sent.release(start, start + 4L), 4L)
  }
  assert_eq(sent.release(2L, 18L), 8L)
  assert_eq(sent.ranges, [(0L, 2L), (18L, 20L), (24L, 28L), (32L, 40L)])
  assert_eq(sent.release(2L, 18L), 0L)
  assert_eq(sent.release(2L, 28L), 6L)
  assert_eq(sent.bytes, 10L)
  assert_eq(sent.ranges, [(0L, 2L), (32L, 40L)])
}
