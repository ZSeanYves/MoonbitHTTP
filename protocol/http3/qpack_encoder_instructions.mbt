///|
fn QpackEncoder::parse_decoder_instruction(
  self : QpackEncoder,
  input : BytesView,
) -> Result[Int, QpackParseError] {
  if input.is_empty() {
    return Err(QpackParseNeedMore)
  }
  let first = input[0].to_int()
  if (first & 0x80) != 0 {
    let (stream_id, used) = match qpack_decode_integer(input, 7) {
      Ok(result) => result
      Err(error) => return Err(error)
    }
    match self.acknowledge_section(stream_id) {
      Ok(_) => Ok(used)
      Err(Http3ConnectionError(_, message)) => Err(QpackParseMalformed(message))
      Err(_) => Err(QpackParseMalformed("invalid Section Acknowledgment"))
    }
  } else if (first & 0x40) != 0 {
    let (stream_id, used) = match qpack_decode_integer(input, 6) {
      Ok(result) => result
      Err(error) => return Err(error)
    }
    match self.cancel_stream_references(stream_id) {
      Ok(_) => Ok(used)
      Err(Http3ConnectionError(_, message)) => Err(QpackParseMalformed(message))
      Err(_) => Err(QpackParseMalformed("invalid Stream Cancellation"))
    }
  } else {
    let (increment, used) = match qpack_decode_integer(input, 6) {
      Ok(result) => result
      Err(error) => return Err(error)
    }
    if increment == 0L ||
      increment > self.total_inserts - self.known_received_count {
      return Err(QpackParseMalformed("invalid Insert Count Increment"))
    }
    self.known_received_count += increment
    Ok(used)
  }
}

///|
pub fn QpackEncoder::feed_decoder_stream(
  self : QpackEncoder,
  bytes : BytesView,
) -> Result[Unit, Http3Error] {
  if self.failure is Some(error) {
    return Err(error)
  }
  if self.decoder_buffer.length() > self.limits.max_instruction_buffer_bytes ||
    bytes.length() >
    self.limits.max_instruction_buffer_bytes - self.decoder_buffer.length() {
    let error = Http3LimitExceeded(
      "QPACK decoder instruction buffer",
      self.limits.max_instruction_buffer_bytes,
    )
    self.failure = Some(error)
    return Err(error)
  }
  h3_append_bytes(self.decoder_buffer, bytes)
  let mut cursor = 0
  while cursor < self.decoder_buffer.length() {
    let parsed = match
      qpack_instruction_length(
        self.decoder_buffer,
        cursor,
        false,
        self.limits.max_decoded_field_section_bytes,
      ) {
      Ok(length) =>
        self.parse_decoder_instruction(
          Bytes::from_array(self.decoder_buffer[cursor:cursor + length]),
        )
      Err(error) => Err(error)
    }
    match parsed {
      Err(QpackParseNeedMore) => break
      Err(error) => {
        let error = qpack_parse_error(
          error,
          QpackDecoderStreamError,
          "QPACK decoder instruction",
        )
        self.failure = Some(error)
        return Err(error)
      }
      Ok(used) => cursor += used
    }
  }
  if cursor > 0 {
    self.decoder_buffer = self.decoder_buffer[cursor:].to_owned()
  }
  Ok(())
}

///|
pub fn QpackEncoder::finish_decoder_stream(
  self : QpackEncoder,
) -> Result[Unit, Http3Error] {
  if self.failure is Some(error) {
    return Err(error)
  }
  if !self.decoder_buffer.is_empty() {
    let error = Http3ConnectionError(
      QpackDecoderStreamError,
      "QPACK decoder stream ended mid-instruction",
    )
    self.failure = Some(error)
    return Err(error)
  }
  Ok(())
}
