///|
test "older service names work with the versioned connection APIs" {
  let connection = @service.ClientConnection::new((), ()).unwrap()
  @service.Http1ClientConnection::close(connection)
  assert_true(connection.is_closed())
  let config = @service.H2ClientConfig::defaults()
  assert_eq(@service.Http2ClientConfig::validate(config), Ok(()))
  let timeout : Error = @service.ClientConnectionTimeout(RequestHeaders)
  assert_true(
    timeout
    is @service.Http1ClientTimeout::ClientConnectionTimeout(RequestHeaders),
  )
  let origin_error : Error = @service.H3ClientError::InvalidOrigin
  assert_true(origin_error is @service.Http3ClientError::InvalidOrigin)
  let signal = @service.H3ServerShutdown::new()
  signal.begin()
  assert_true(signal.started())
  assert_true(signal.has_started())
}
