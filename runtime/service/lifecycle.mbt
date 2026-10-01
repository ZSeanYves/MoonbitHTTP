///|
priv suberror ConnectionScopeCancelled derive(Debug)

///|
/// Runs a connection scope and reports its terminal state exactly once. The
/// pessimistic initial state ensures asynchronous cancellation is observable
/// even if cancellation stops being catchable by ordinary `catch` handlers.
async fn[X] run_connection_scope(
  operation : async () -> X,
  close_callback : ((Error?) -> Unit)?,
) -> X {
  let mut terminal : Error? = Some(ConnectionScopeCancelled)
  defer (if close_callback is Some(callback) { callback(terminal) })
  let outcome : Result[X, Error] = Ok(operation()) catch { error => Err(error) }
  match outcome {
    Ok(value) => {
      terminal = None
      value
    }
    Err(error) => {
      terminal = Some(error)
      raise error
    }
  }
}
