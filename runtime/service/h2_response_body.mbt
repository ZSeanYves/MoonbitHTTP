///|
/// Validate before publishing DATA: receive credit bounds outstanding bytes,
/// while this counter bounds the complete response, including consumed bytes.
fn H2ClientStream::accept_response_data(
  self : H2ClientStream,
  length : Int,
  end_stream : Bool,
  max_body_bytes : Int,
) -> Result[Unit, @http2.H2ProtocolError] {
  if !self.response_started {
    return Err(
      StreamError(self.id, ProtocolError, "DATA before final response headers"),
    )
  }
  if !self.response_body_allowed && length > 0 {
    return Err(
      StreamError(self.id, ProtocolError, "response body is forbidden"),
    )
  }
  if self.response_body_bytes > max_body_bytes ||
    length > max_body_bytes - self.response_body_bytes {
    return Err(
      StreamError(
        self.id,
        EnhanceYourCalm,
        "response body exceeds configured limit",
      ),
    )
  }
  if self.expected_response_bytes is Some(expected) {
    if self.response_body_bytes > expected ||
      length > expected - self.response_body_bytes {
      return Err(
        StreamError(self.id, ProtocolError, "response exceeds content-length"),
      )
    }
    if end_stream && self.response_body_bytes + length != expected {
      return Err(
        StreamError(
          self.id,
          ProtocolError,
          "response ended before content-length",
        ),
      )
    }
  }
  self.response_body_bytes += length
  Ok(())
}
