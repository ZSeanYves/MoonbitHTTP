///|
/// Preserve the original transport failure at HTTP and socket boundaries.
pub fn io_cause(error : Error) -> Error {
  for current = error {
    match current {
      @aio.ReaderError::TransportError(cause, ..)
      | @aio.WriterError::TransportError(cause, ..) => continue cause
      _ => break current
    }
  }
}
