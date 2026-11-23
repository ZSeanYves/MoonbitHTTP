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
  let body = b"12345678abcdefgh"
  guard client.send_stream_prefix(id, body, true, 0L).unwrap()
    is Some((8, SendDatagram(_, packet))) else {
    fail("expected stream packet")
  }
  let received = server.on_datagram(endpoint, packet, 1L).unwrap()
  assert_true(received.contains(StreamData(id, b"12345678", false)))
  assert_eq(client.send_stream_prefix(id, body[8:], true, 2L), Ok(None))
  for action in received {
    if action is SendDatagram(_, ack) {
      ignore(client.on_datagram(endpoint, ack, 3L).unwrap())
    }
  }
  assert_eq(client.connection().retained_send_bytes, 0L)
  assert_eq(client.send_stream_prefix(id, body[8:], true, 3L), Ok(None))
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
  guard client.send_stream_prefix(id, body[8:], true, 7L).unwrap()
    is Some((8, SendDatagram(_, next))) else {
    fail("expected second stream packet")
  }
  assert_true(
    server
    .on_datagram(endpoint, next, 8L)
    .unwrap()
    .contains(StreamData(id, b"abcdefgh", true)),
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

///|
test "STOP_SENDING cancels a lost FIN and reliably resets through congestion" {
  let endpoint = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  let (client, server) = key_limit_driver_pair(endpoint, endpoint)
  let id = client.connection().open_bidirectional_stream().unwrap()
  guard client.send_stream(id, b"first", false, 0L).unwrap()
    is SendDatagram(_, first) else {
    fail("stream datagram")
  }
  for action in server.on_datagram(endpoint, first, 1L).unwrap() {
    if action is SendDatagram(_, ack) {
      ignore(client.on_datagram(endpoint, ack, 2L).unwrap())
    }
  }
  // Drop the FIN. Even after receiving the complete response the client must
  // remember the outgoing final size and remain able to honour STOP_SENDING.
  ignore(client.send_stream(id, b"last", true, 3L).unwrap())
  let mixed = StreamFrame::new(id, 5L, b"last", true).unwrap()
  ignore(client.send_frames(Application, [Stream(mixed), Ping], 3L).unwrap())
  guard server.send_stream(id, b"reply", true, 4L).unwrap()
    is SendDatagram(_, reply) else {
    fail("response datagram")
  }
  assert_true(
    client
    .on_datagram(endpoint, reply, 5L)
    .unwrap()
    .contains(StreamData(id, b"reply", true)),
  )
  let in_flight = client.recovery.bytes_in_flight
  client.recovery.bytes_in_flight = client.recovery.congestion_window
  guard server.stop_sending(id, 42L, 6L).unwrap() is Some(SendDatagram(_, stop)) else {
    fail("stop datagram")
  }
  assert_eq(server.stop_sending(id, 7L, 6L), Ok(None))
  assert_true(
    client
    .on_datagram(endpoint, stop, 7L)
    .unwrap()
    .contains(SendStopped(id, 42L)),
  )
  assert_eq(client.connection().retained_send_bytes, 0L)
  assert_eq(client.retransmissions.map(entry => entry.frames), [[Ping]])
  assert_true(client.send_stream(id, b"x", false, 8L) is Err(StreamClosed(_)))
  assert_eq(client.poll(8L).unwrap(), [])
  assert_eq(client.pending_resets.length(), 1)
  client.recovery.bytes_in_flight = in_flight
  // Drop this first RESET_STREAM, too. ACK a later independent stream to
  // trigger real time-threshold loss detection and retransmission.
  assert_eq(client.poll(9L).unwrap().length(), 1)
  assert_eq(client.pending_resets.length(), 0)
  let other = client.connection().open_bidirectional_stream().unwrap()
  guard client.send_stream(other, b"ok", true, 80L).unwrap()
    is SendDatagram(_, next) else {
    fail("other stream datagram")
  }
  let received = server.on_datagram(endpoint, next, 81L).unwrap()
  assert_true(received.contains(StreamData(other, b"ok", true)))
  let events : Array[QuicDriverAction] = []
  for action in received {
    if action is SendDatagram(_, ack) {
      for retry in client.on_datagram(endpoint, ack, 82L).unwrap() {
        if retry is SendDatagram(_, packet) {
          events.append(server.on_datagram(endpoint, packet, 83L).unwrap())
        }
      }
    }
  }
  assert_true(events.contains(StreamReset(id, 42L)))
  assert_eq(
    server.connection().streams.get(id).unwrap().recv_final_size,
    Some(9L),
  )
  for action in events {
    if action is SendDatagram(_, ack) {
      ignore(client.on_datagram(endpoint, ack, 84L).unwrap())
    }
  }
  assert_true(client.connection().is_retired(id))
}
