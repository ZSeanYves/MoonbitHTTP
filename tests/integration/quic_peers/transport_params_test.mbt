///|
fn established_connection(
  role : @quic.QuicRole,
  params : @quic.QuicTransportParams,
) -> @quic.QuicConnection {
  let connection = @quic.QuicConnection::new(role, transport_params=params).unwrap()
  connection.set_peer_transport_params(params).unwrap()
  connection.establish().unwrap()
  connection
}

///|
test "QUIC connection uses authenticated peer credit and bidirectional roles" {
  let client = @quic.QuicConnection::new(Client).unwrap()
  assert_true(client.establish() is Err(Unsupported(_)))
  let peer = @quic.QuicTransportParams::{
    ..@quic.QuicTransportParams::defaults(),
    initial_max_data: 2L,
  }
  client.set_peer_transport_params(peer).unwrap()
  assert_true(client.set_peer_transport_params(peer) is Err(_))
  client.establish().unwrap()
  let server = established_connection(
    Server,
    @quic.QuicTransportParams::defaults(),
  )
  let id = client.open_bidirectional_stream().unwrap()
  assert_eq(id, 0L)
  let request = client.send_stream(id, b"ok", true).unwrap()
  assert_eq(server.receive_frame(request).unwrap(), [
    StreamData(id, b"ok", true),
  ])
  let response = server.send_stream(id, b"reply", true).unwrap()
  assert_eq(client.receive_frame(response).unwrap(), [
    StreamData(id, b"reply", true),
  ])
  let second = client.open_bidirectional_stream().unwrap()
  assert_true(
    client.send_stream(second, b"x", false) is Err(FlowControl(0L, _)),
  )
}

///|
test "QUIC unidirectional streams have separate credit and direction" {
  let params = @quic.QuicTransportParams::{
    ..@quic.QuicTransportParams::defaults(),
    initial_max_streams_uni: 1L,
  }
  let client = established_connection(Client, params)
  let server = established_connection(Server, params)
  let id = client.open_unidirectional_stream().unwrap()
  assert_eq(id, 2L)
  assert_true(client.open_unidirectional_stream() is Err(FlowControl(_)))
  let frame = client.send_stream(id, b"control", false).unwrap()
  assert_eq(server.receive_frame(frame).unwrap(), [
    StreamData(id, b"control", false),
  ])
  assert_true(
    server.send_stream(id, b"wrong direction", false) is Err(Protocol(_)),
  )
  assert_true(client.receive_frame(frame) is Err(Protocol(_)))
  assert_eq(client.receive_frame(MaxStreams(true, 2L)), Ok([]))
  assert_eq(client.open_unidirectional_stream(), Ok(6L))
}
