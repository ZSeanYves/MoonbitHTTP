///|
/// Preserve host error identity before it crosses the transport boundary.
/// A deadline wrapper may raise any I/O error, not only TimeoutError.
fn native_transport_error(
  operation : @transport_api.TransportOperation,
  error : Error,
) -> @transport_api.TransportError {
  match error {
    @async.TimeoutError => Timeout(operation)
    @os_error.OSError(code, ..) => SystemFailure(operation, code, "\{error}")
    _ => Failed(operation, "\{error}")
  }
}

///|
async fn[A] native_io(
  operation : @transport_api.TransportOperation,
  timeout_ms : Int?,
  action : async () -> A,
) -> Result[A, @transport_api.TransportError] {
  Ok(
    match timeout_ms {
      Some(timeout) => @async.with_timeout(timeout, action)
      None => action()
    },
  ) catch {
    error => Err(native_transport_error(operation, error))
  }
}
