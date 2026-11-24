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
  fin~ : Bool = false,
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
