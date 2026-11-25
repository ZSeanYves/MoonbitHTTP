///|
/// Preserve host error identity before it crosses the transport boundary.
/// A deadline wrapper may raise any I/O error, not only TimeoutError.
pub fn translate_io_error(
  operation : @transport_api.TransportOperation,
  error : Error,
) -> @transport_api.TransportError {
  let error = @async_support.io_cause(error)
  match error {
    @async.TimeoutError => Timeout(operation)
    @os_error.OsError(_, raw_code=code, ..) =>
      SystemFailure(operation, code, "\{error}")
    _ => Failed(operation, "\{error}")
  }
}

///|
async fn[A] native_io(
  operation : @transport_api.TransportOperation,
  timeout_ms : Int32?,
  action : async () -> A,
) -> Result[A, @transport_api.TransportError] {
  Ok(
    match timeout_ms {
      Some(timeout) => @async.with_timeout(timeout, action)
      None => action()
    },
  ) catch {
    error => Err(translate_io_error(operation, error))
  }
}
