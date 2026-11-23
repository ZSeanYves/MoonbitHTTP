///|
fn receive_connection(max_data : Int64) -> @quic.QuicConnection {
  let connection = @quic.QuicConnection::new(Server, transport_params={
    ..@quic.QuicTransportParams::defaults(),
    initial_max_data: max_data,
  }).unwrap()
  connection
  .set_peer_transport_params(@quic.QuicTransportParams::defaults())
  .unwrap()
  connection.establish().unwrap()
  connection
}

///|
fn stream(
  id : Int64,
  offset : Int64,
  data : Bytes,
  fin? : Bool = false,
) -> @quic.QuicFrame {
  Stream(@quic.StreamFrame::new(id, offset, data, fin).unwrap())
}

///|
test "QUIC connection credit counts sparse offsets and avoids duplicate accounting" {
  let connection = receive_connection(10L)
  assert_eq(connection.receive_frame(stream(0L, 9L, b"j")).unwrap(), [])
  // Filling the gap and replaying it spend no extra connection credit.
  assert_eq(connection.receive_frame(stream(0L, 0L, b"abcdefghi")).unwrap(), [
    StreamData(0L, b"abcdefghij", false),
  ])
  assert_eq(connection.receive_frame(stream(0L, 0L, b"abcdefghi")).unwrap(), [])
  assert_true(
    connection.receive_frame(stream(4L, 0L, b"x")) is Err(FlowControl(0L, _)),
  )
  let smaller = receive_connection(9L)
  assert_true(
    smaller.receive_frame(stream(0L, 9L, b"j")) is Err(FlowControl(0L, _)),
  )
}

///|
test "QUIC RESET_STREAM accounts final size even without preceding STREAM" {
  let connection = receive_connection(10L)
  assert_eq(connection.receive_frame(ResetStream(0L, 42L, 8L)).unwrap(), [
    StreamReset(0L, 42L),
  ])
  assert_eq(connection.receive_frame(ResetStream(0L, 42L, 8L)).unwrap(), [])
  assert_eq(connection.receive_frame(stream(0L, 0L, b"abcd")).unwrap(), [])
  assert_true(
    connection.receive_frame(ResetStream(4L, 42L, 3L))
    is Err(FlowControl(0L, _)),
  )
  assert_eq(connection.receive_frame(ResetStream(4L, 42L, 2L)).unwrap(), [
    StreamReset(4L, 42L),
  ])
  assert_true(
    connection.receive_frame(ResetStream(0L, 42L, 9L)) is Err(Protocol(6L, _)),
  )
  // Reset releases both missing and buffered bytes before the reply finishes.
  assert_eq(connection.take_credit_updates(), [MaxData(20L)])
  let reply = connection.send_stream(0L, b"reply", true).unwrap()
  assert_eq(connection.take_credit_updates(), [])
  connection.acknowledge_stream_frame(reply).unwrap()
  assert_eq(connection.take_credit_updates(), [MaxStreams(false, 101L)])
}

///|
test "QUIC FIN cannot shrink the previously observed highest offset" {
  let connection = receive_connection(20L)
  connection.receive_frame(stream(0L, 9L, b"j")).unwrap() |> ignore
  assert_true(
    connection.receive_frame(stream(0L, 0L, b"a", fin=true))
    is Err(Protocol(6L, _)),
  )
  assert_true(
    connection.receive_frame(ResetStream(0L, 0L, 9L)) is Err(Protocol(6L, _)),
  )
}

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
  assert_eq(server.receive_frame(stream(0L, 0L, b"ping", fin=true)).unwrap(), [])
  // Only the most recent final sizes are retained for diagnostics.
  assert_true(
    server.receive_frame(ResetStream(1196L, 0L, 5L)) is Err(Protocol(6L, _)),
  )
}

///|
test "QUIC peer streams can arrive out of order and reset only their receive direction" {
  let server = receive_connection(20L)
  assert_eq(server.receive_frame(stream(8L, 0L, b"c", fin=true)).unwrap(), [
    StreamData(8L, b"c", true),
  ])
  let last = server.send_stream(8L, b"", true).unwrap()
  server.acknowledge_stream_frame(last).unwrap()
  assert_eq(server.receive_frame(ResetStream(0L, 42L, 3L)).unwrap(), [
    StreamReset(0L, 42L),
  ])
  let reply = server.send_stream(0L, b"reply", true).unwrap()
  server.acknowledge_stream_frame(reply).unwrap()
  assert_eq(server.receive_frame(stream(4L, 0L, b"b", fin=true)).unwrap(), [
    StreamData(4L, b"b", true),
  ])
  let fin = server.send_stream(4L, b"", true).unwrap()
  server.acknowledge_stream_frame(fin).unwrap()
  assert_eq(server.receive_frame(MaxStreamData(4L, 100L)).unwrap(), [])
  assert_eq(server.receive_frame(ResetStream(0L, 42L, 3L)).unwrap(), [])
  assert_eq(server.take_credit_updates(), [
    MaxData(25L),
    MaxStreams(false, 103L),
  ])
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
    assert_eq(server.receive_frame(stream(id, offset, b"xxx456")).unwrap(), [])
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

///|
test "peer send controls share stream direction, opening and replay rules" {
  let server = receive_connection(12L)
  for
    frame in [
      @quic.QuicFrame::StopSending(2L, 42L),
      MaxStreamData(2L, 4L),
      StopSending(1L, 0L),
      StopSending(3L, 0L),
    ] {
    assert_true(server.receive_frame(frame) is Err(Protocol(5L, _)))
  }
  assert_eq(server.receive_frame(StopSending(4L, 42L)).unwrap(), [
    SendStopped(4L, 42L),
    SendFrame(ResetStream(4L, 42L, 0L)),
  ])
  assert_eq(server.receive_frame(StopSending(4L, 17L)).unwrap(), [])
  assert_eq(server.receive_frame(stream(4L, 0L, b"body", fin=true)).unwrap(), [
    StreamData(4L, b"body", true),
  ])
  server.acknowledge_stream_frame(ResetStream(4L, 42L, 0L)).unwrap()
  assert_eq(server.receive_frame(StopSending(4L, 17L)).unwrap(), [])
  // Stop reading while both unread bytes and an out-of-order suffix exist.
  ignore(server.receive_frame(stream(0L, 0L, b"ab")).unwrap())
  ignore(server.receive_frame(stream(0L, 4L, b"ef")).unwrap())
  assert_eq(server.stop_sending(0L, 42L), Ok(Some(StopSending(0L, 42L))))
  assert_eq(server.receive_frame(stream(0L, 2L, b"cd")).unwrap(), [])
  assert_eq(server.receive_frame(ResetStream(0L, 42L, 8L)).unwrap(), [
    StreamReset(0L, 42L),
  ])
  assert_eq(server.take_credit_updates(), [
    MaxData(24L),
    MaxStreams(false, 101L),
  ])
}
