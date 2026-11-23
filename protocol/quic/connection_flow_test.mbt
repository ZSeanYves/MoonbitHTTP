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
  ignore(server.send_stream(8L, b"", true).unwrap())
  assert_eq(server.receive_frame(ResetStream(0L, 42L, 3L)).unwrap(), [
    StreamReset(0L, 42L),
  ])
  assert_true(server.send_stream(0L, b"reply", true) is Ok(_))
  assert_eq(server.receive_frame(stream(4L, 0L, b"b", fin=true)).unwrap(), [
    StreamData(4L, b"b", true),
  ])
  ignore(server.send_stream(4L, b"", true).unwrap())
  assert_eq(server.receive_frame(MaxStreamData(4L, 100L)).unwrap(), [])
  assert_eq(server.receive_frame(ResetStream(0L, 42L, 3L)).unwrap(), [])
  assert_eq(server.take_credit_updates(), [
    MaxData(25L),
    MaxStreams(false, 103L),
  ])
}
