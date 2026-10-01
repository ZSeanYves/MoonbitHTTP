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
