///|
test "QUIC transport parameters preserve identities and use RFC omitted defaults" {
  let cid = @quic.ConnectionId::new(b"client").unwrap()
  let params = @quic.QuicTransportParameters::new(cid)
  let wire = params.encode(Client).unwrap()
  assert_eq(@quic.QuicTransportParameters::decode(wire, Client), Ok(params))
  let minimal = @quic.QuicTransportParameters::decode(b"\x0f\x01c", Client).unwrap()
  assert_eq(minimal.limits.initial_max_data, 0L)
  assert_eq(minimal.limits.initial_max_streams_bidi, 0L)
  assert_eq(minimal.limits.max_udp_payload_size, 65527)
  assert_eq(minimal.ack_delay_exponent, 3)
  assert_true(
    minimal.validate_connection_ids(cid) is Err(InvalidTransportParameter(_)),
  )
}

///|
test "QUIC transport parameters reject duplicates lengths roles and bounds" {
  for
    wire in [
      b"\x0f\x01c\x0f\x01c", // duplicate required parameter
       b"\x0f\x01c\x21\x00\x21\x00", // unknown duplicates also fail
       b"\x0f\x01c\x01\x02\x00\x00", // integer length must be exact
       b"\x0f\x01c\x0a\x01\x15", // ACK exponent > 20
       b"\x0f\x01c\x0c\x01\x00", // flag must have zero length
       b"\x0f\x01c\x00\x01s", // server-only parameter from client
       b"\x0f\x03x", // truncated CID
       b"\x01\x01\x00", // missing initial_source_connection_id
    ] {
    assert_true(@quic.QuicTransportParameters::decode(wire, Client) is Err(_))
  }
  assert_true(
    @quic.QuicTransportParameters::decode(b"\x0f\x01s", Server) is Err(_),
  )
  assert_true(
    @quic.QuicTransportParameters::decode(
      b"\x0f\x01c\x21\x00",
      Client,
      max_parameters=1,
    )
    is Err(LimitExceeded(_)),
  )
}

///|
test "QUIC transport parameters authenticate original and Retry connection IDs" {
  let initial = @quic.ConnectionId::new(b"server").unwrap()
  let original = @quic.ConnectionId::new(b"original").unwrap()
  let retry = @quic.ConnectionId::new(b"retry").unwrap()
  let params = @quic.QuicTransportParameters::{
    ..@quic.QuicTransportParameters::new(
      initial,
      original_destination_connection_id=Some(original),
    ),
    retry_source_connection_id: Some(retry),
  }
  assert_eq(
    @quic.QuicTransportParameters::decode(
      params.encode(Server).unwrap(),
      Server,
    ),
    Ok(params),
  )
  assert_eq(
    params.validate_connection_ids(
      initial,
      expected_original=Some(original),
      expected_retry=Some(retry),
    ),
    Ok(()),
  )
  assert_true(
    params.validate_connection_ids(initial, expected_original=Some(original))
    is Err(_),
  )
}

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
