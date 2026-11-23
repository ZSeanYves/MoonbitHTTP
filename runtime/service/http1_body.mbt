///|
/// Drive a Body through the protocol's sole outgoing framing state machine.
/// The enclosing body scope owns cancellation across both headers and frames.
async fn write_http1_body(
  framing : @http1.BodyFraming,
  next_frame : async () -> @body.Frame?,
  write : async (Bytes) -> Unit,
) -> Unit {
  let encoder = match @http1.BodyEncoder::new(framing) {
    Ok(value) => value
    Err(error) => raise error
  }
  while next_frame() is Some(frame) {
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
