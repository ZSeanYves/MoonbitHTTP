///|
test "QUIC reuses one connection across stream and byte windows" {
  let params = @quic.QuicTransportParams::{
    ..@quic.QuicTransportParams::defaults(),
    initial_max_data: 4L,
    initial_max_streams_bidi: 2L,
  }
  let limits = @quic.QuicLimits::{
    ..@quic.QuicLimits::defaults(),
    max_streams: 2,
    max_connection_data: 4L,
  }
  let client = @quic.QuicConnection::new(
    Client,
    limits~,
    transport_params=params,
  ).unwrap()
  let server = @quic.QuicConnection::new(
    Server,
    limits~,
    transport_params=params,
  ).unwrap()
  for side in [client, server] {
    side.set_peer_transport_params(params).unwrap()
    side.establish().unwrap()
  }
  for i in 0..<300 {
    let id = client.open_bidirectional_stream().unwrap()
    assert_eq(id, i.to_int64() * 4L)
    let request = client.send_stream(id, b"ping", true).unwrap()
    assert_eq(server.receive_frame(request).unwrap(), [
      StreamData(id, b"ping", true),
    ])
    let response = server.send_stream(id, b"pong", true).unwrap()
    assert_eq(client.receive_frame(response).unwrap(), [
      StreamData(id, b"pong", true),
    ])
    assert_eq(server.receive_frame(request).unwrap(), [])
    assert_eq(client.receive_frame(response).unwrap(), [])
    client.acknowledge_stream_frame(request).unwrap()
    server.acknowledge_stream_frame(response).unwrap()
    for (sender, receiver) in [(client, server), (server, client)] {
      for frame in sender.take_credit_updates() {
        assert_eq(receiver.receive_frame(frame).unwrap(), [])
      }
      assert_eq(sender.take_credit_updates(), [])
    }
  }
  assert_eq(
    server
    .receive_frame(
      Stream(@quic.StreamFrame::new(0L, 0L, b"ping", true).unwrap()),
    )
    .unwrap(),
    [],
  )
  // Only the most recent final sizes are retained for diagnostics.
  assert_true(
    server.receive_frame(ResetStream(1196L, 0L, 5L)) is Err(Protocol(6L, _)),
  )
}

///|
test "QUIC consumption and ACKs advance bounded windows on one active stream" {
  let limits = @quic.QuicLimits::{
    ..@quic.QuicLimits::defaults(),
    max_connection_data: 8L,
    max_stream_data: 8L,
  }
  let client = @quic.QuicConnection::new(Client, limits~).unwrap()
  let server = @quic.QuicConnection::new(Server, limits~).unwrap()
  let params = server.local_transport_params()
  assert_eq(params.initial_max_data, 8L)
  assert_eq(params.initial_max_stream_data_bidi_remote, 8L)
  for side in [client, server] {
    side.set_peer_transport_params(params).unwrap()
    side.establish().unwrap()
  }
  let id = client.open_bidirectional_stream().unwrap()
  for i in 0..<65 {
    let offset = i.to_int64() * 8L
    let packet = client.send_stream(id, b"12345678", false).unwrap()
    assert_eq(server.receive_frame(packet).unwrap(), [
      StreamData(id, b"12345678", false),
    ])
    assert_eq(server.take_credit_updates(), [])
    assert_true(server.consume_stream_data(id, 9) is Err(_))
    server.consume_stream_data(id, 3).unwrap()
    // A replay spanning the consumed prefix must still match unread bytes.
    assert_eq(
      server
      .receive_frame(
        Stream(@quic.StreamFrame::new(id, offset, b"xxx456", false).unwrap()),
      )
      .unwrap(),
      [],
    )
    server.consume_stream_data(id, 5).unwrap()
    let next_limit = offset + 16L
    let credit = server.take_credit_updates()
    assert_eq(credit, [MaxData(next_limit), MaxStreamData(id, next_limit)])
    for frame in credit {
      ignore(client.receive_frame(frame).unwrap())
    }
    // Remote credit does not release the sender's local outstanding-byte budget.
    assert_true(client.send_stream(id, b"x", false) is Err(FlowControl(_, _)))
    client.acknowledge_stream_data(id, offset + 1L, 4).unwrap()
    client.acknowledge_stream_data(id, offset + 2L, 2).unwrap()
    assert_true(
      client.send_stream(id, b"12345", false) is Err(FlowControl(_, _)),
    )
    client.acknowledge_stream_data(id, offset, 8).unwrap()
    assert_eq(server.take_credit_updates(), [])
  }
  let fin = client.send_stream(id, b"", true).unwrap()
  assert_eq(server.receive_frame(fin).unwrap(), [StreamData(id, b"", true)])
  let reply = server.send_stream(id, b"", true).unwrap()
  server.acknowledge_stream_frame(reply).unwrap()
  assert_eq(server.take_credit_updates(), [
    MaxStreams(false, params.initial_max_streams_bidi + 1L),
  ])
}
