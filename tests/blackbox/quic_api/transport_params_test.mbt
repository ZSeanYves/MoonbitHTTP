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
