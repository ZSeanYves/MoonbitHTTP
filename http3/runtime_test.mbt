///|
fn h3_request_fields(
  content_length? : String? = None,
) -> Array[@http3.QpackField] {
  let fields = [
    qpack_test_field(":method", "POST"),
    qpack_test_field(":scheme", "https"),
    qpack_test_field(":authority", "example.com"),
    qpack_test_field(":path", "/submit"),
  ]
  match content_length {
    Some(value) => fields.push(qpack_test_field("content-length", value))
    None => ()
  }
  fields
}

///|
fn h3_test_receive_settings(connection : @http3.Http3Connection) -> Unit {
  ignore(connection.receive_control_frame(H3SettingsFrame([])).unwrap())
}

///|
test "http3 runtime: critical streams are unique and cannot close" {
  let connection = @http3.Http3Connection::new(H3Server).unwrap()
  assert_eq(
    connection.register_remote_unidirectional(2L, b"\x00"),
    Ok((H3ControlStream, 1)),
  )
  assert_true(
    connection.register_remote_unidirectional(6L, b"\x00")
    is Err(Http3ConnectionError(H3StreamCreationError, _)),
  )
  assert_true(
    connection.remote_unidirectional_closed(2L)
    is Err(Http3ConnectionError(H3ClosedCriticalStream, _)),
  )
  let connection = @http3.Http3Connection::new(H3Server).unwrap()
  assert_true(
    connection.register_remote_unidirectional(10L, b"\x01\x00")
    is Err(Http3ConnectionError(H3StreamCreationError, _)),
  )
}

///|
test "http3 runtime: SETTINGS is first and unique; GOAWAY only decreases" {
  let missing = @http3.Http3Connection::new(H3Client).unwrap()
  assert_true(
    missing.receive_control_frame(H3Goaway(8L))
    is Err(Http3ConnectionError(H3MissingSettings, _)),
  )
  let connection = @http3.Http3Connection::new(H3Client).unwrap()
  let settings_values : Array[@http3.H3Setting] = [
    { id: @http3.H3_SETTINGS_QPACK_MAX_TABLE_CAPACITY, value: 0L, },
    { id: @http3.H3_SETTINGS_ENABLE_CONNECT_PROTOCOL, value: 1L, },
  ]
  let settings : @http3.Http3Frame = H3SettingsFrame(settings_values)
  assert_true(connection.receive_control_frame(settings) is Ok(_))
  let duplicate : @http3.Http3Frame = H3SettingsFrame([])
  assert_true(
    connection.receive_control_frame(duplicate)
    is Err(Http3ConnectionError(H3FrameUnexpected, _)),
  )
  let connection = @http3.Http3Connection::new(H3Client).unwrap()
  let empty_settings : @http3.Http3Frame = H3SettingsFrame([])
  ignore(connection.receive_control_frame(empty_settings).unwrap())
  assert_true(connection.receive_control_frame(H3Goaway(12L)) is Ok(_))
  assert_true(connection.receive_control_frame(H3Goaway(8L)) is Ok(_))
  assert_true(
    connection.receive_control_frame(H3Goaway(16L))
    is Err(Http3ConnectionError(H3IdError, _)),
  )
}

///|
test "http3 runtime: request headers, data, trailers, and length complete" {
  let connection = @http3.Http3Connection::new(H3Server).unwrap()
  h3_test_receive_settings(connection)
  connection.accept_request_stream(0L).unwrap()
  let headers = @http3.qpack_encode_static(
    h3_request_fields(content_length=Some("5")),
  ).unwrap()
  let actions = connection
    .receive_request_frame(0L, H3Headers(headers))
    .unwrap()
  assert_true(actions[0] is H3HeadersReceived(0L, _, false, false))
  assert_true(connection.receive_request_frame(0L, H3Data(b"hello")) is Ok(_))
  let trailers = @http3.qpack_encode_static([
    qpack_test_field("x-checksum", "ok"),
  ]).unwrap()
  assert_true(
    connection.receive_request_frame(0L, H3Headers(trailers)) is Ok(_),
  )
  assert_eq(connection.finish_request_stream(0L), Ok(()))
  assert_eq(connection.stream_phase(0L), None)
}

///|
test "http3 runtime: request authority, scheme, method, path, and Host are strict" {
  let valid = h3_request_fields()
  assert_true(
    @http3.validate_http3_field_section(0L, valid, H3RequestFields) is Ok(_),
  )
  let invalid_scheme = valid.copy()
  invalid_scheme[1] = qpack_test_field(":scheme", "ftp")
  assert_true(
    @http3.validate_http3_field_section(0L, invalid_scheme, H3RequestFields)
    is Err(Http3StreamError(_, H3MessageError, _)),
  )
  let invalid_method = valid.copy()
  invalid_method[0] = qpack_test_field(":method", "BAD METHOD")
  assert_true(
    @http3.validate_http3_field_section(0L, invalid_method, H3RequestFields)
    is Err(Http3StreamError(_, H3MessageError, _)),
  )
  let invalid_host = valid.copy()
  invalid_host.push(qpack_test_field("host", "other.example"))
  assert_true(
    @http3.validate_http3_field_section(0L, invalid_host, H3RequestFields)
    is Err(Http3StreamError(_, H3MessageError, _)),
  )
  let missing_authority = valid.copy()
  missing_authority.remove(2) |> ignore
  assert_true(
    @http3.validate_http3_field_section(0L, missing_authority, H3RequestFields)
    is Err(Http3StreamError(_, H3MessageError, _)),
  )
  let invalid_authority = valid.copy()
  invalid_authority[2] = qpack_test_field(":authority", "[not-an-ip]")
  assert_true(
    @http3.validate_http3_field_section(0L, invalid_authority, H3RequestFields)
    is Err(Http3StreamError(_, H3MessageError, _)),
  )
}

///|
test "http3 runtime: invalid frame order and content length are rejected" {
  let connection = @http3.Http3Connection::new(H3Server).unwrap()
  h3_test_receive_settings(connection)
  connection.accept_request_stream(0L).unwrap()
  assert_true(
    connection.receive_request_frame(0L, H3Data(b"early"))
    is Err(Http3StreamError(0L, H3FrameUnexpected, _)),
  )
  let connection = @http3.Http3Connection::new(H3Server).unwrap()
  h3_test_receive_settings(connection)
  connection.accept_request_stream(0L).unwrap()
  let headers = @http3.qpack_encode_static(
    h3_request_fields(content_length=Some("4")),
  ).unwrap()
  ignore(connection.receive_request_frame(0L, H3Headers(headers)).unwrap())
  assert_true(
    connection.receive_request_frame(0L, H3Data(b"hello"))
    is Err(Http3StreamError(0L, H3MessageError, _)),
  )
  let connection = @http3.Http3Connection::new(H3Server).unwrap()
  h3_test_receive_settings(connection)
  connection.accept_request_stream(0L).unwrap()
  let headers = @http3.qpack_encode_static(
    h3_request_fields(content_length=Some("5")),
  ).unwrap()
  ignore(connection.receive_request_frame(0L, H3Headers(headers)).unwrap())
  ignore(connection.receive_request_frame(0L, H3Data(b"four")).unwrap())
  assert_true(
    connection.finish_request_stream(0L)
    is Err(Http3StreamError(0L, H3MessageError, _)),
  )
}

///|
test "http3 runtime: response permits informational headers and forbids body for HEAD" {
  let connection = @http3.Http3Connection::new(H3Client).unwrap()
  h3_test_receive_settings(connection)
  let stream_id = connection
    .open_request_stream(request_method=Some("HEAD"))
    .unwrap()
  let informational = @http3.qpack_encode_static([
    qpack_test_field(":status", "103"),
  ]).unwrap()
  let actions = connection
    .receive_request_frame(stream_id, H3Headers(informational))
    .unwrap()
  assert_true(actions[0] is H3HeadersReceived(_, _, false, true))
  let final_fields = @http3.qpack_encode_static([
    qpack_test_field(":status", "200"),
    qpack_test_field("content-length", "100"),
  ]).unwrap()
  ignore(
    connection
    .receive_request_frame(stream_id, H3Headers(final_fields))
    .unwrap(),
  )
  assert_true(
    connection.receive_request_frame(stream_id, H3Data(b"x"))
    is Err(Http3StreamError(_, H3MessageError, _)),
  )
  assert_eq(connection.finish_request_stream(stream_id), Ok(()))
}

///|
test "http3 runtime: unknown frames are ignored and cancellation releases state" {
  let connection = @http3.Http3Connection::new(H3Server).unwrap()
  h3_test_receive_settings(connection)
  connection.accept_request_stream(0L).unwrap()
  assert_eq(
    connection.receive_request_frame(0L, H3Unknown(0x21L, b"padding")),
    Ok([H3UnknownFrameIgnored(0x21L)]),
  )
  assert_true(connection.cancel_request_stream(0L) is Ok(_))
  assert_eq(connection.stream_phase(0L), None)
}
