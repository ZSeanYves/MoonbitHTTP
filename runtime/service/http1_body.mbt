///|
/// Own the outgoing body until its headers and frames have been written.
/// The connection scope preserves the original error and handles asynchronous
/// cancellation; the body receives exactly one cancellation notification.
async fn[B : @body.Body, X] with_outgoing_body_scope(
  body : B,
  operation : async () -> X,
) -> X {
  run_connection_scope(
    operation,
    Some(fn(error) {
      match error {
        Some(ConnectionScopeCancelled) =>
          body.cancel(@body.BodyError::Cancelled)
        Some(error) => body.cancel(error)
        None => ()
      }
    }),
  )
}

///|
/// Drive a Body through the protocol's sole outgoing framing state machine.
/// The enclosing body scope owns cancellation across both headers and frames.
async fn[B : @body.Body] write_http1_body(
  body : B,
  framing : @http1.BodyFraming,
  write : async (Bytes) -> Unit,
) -> Unit {
  let encoder = match @http1.BodyEncoder::new(framing) {
    Ok(value) => value
    Err(error) => raise error
  }
  while body.next_frame() is Some(frame) {
    let encoded = match frame {
      Data(data) => encoder.data(data)
      Trailers(fields) => encoder.trailers(fields)
    }
    let bytes = match encoded {
      Ok(bytes) => bytes
      Err(error) => raise error
    }
    if !bytes.is_empty() {
      write(bytes)
    }
  }
  let ending = match encoder.finish() {
    Ok(bytes) => bytes
    Err(error) => raise error
  }
  if !ending.is_empty() {
    write(ending)
  }
}
