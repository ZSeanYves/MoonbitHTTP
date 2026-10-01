///|
fn QpackEncoder::parse_decoder_instruction(
  self : QpackEncoder,
) -> Result[Int, QpackParseError] {
  if self.decoder_buffer.is_empty() {
    return Err(QpackParseNeedMore)
  }
  let input = Bytes::from_array(self.decoder_buffer)
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
  while !self.decoder_buffer.is_empty() {
    match self.parse_decoder_instruction() {
      Err(QpackParseNeedMore) => return Ok(())
      Err(error) => {
        let error = qpack_parse_error(
          error,
          QpackDecoderStreamError,
          "QPACK decoder instruction",
        )
        self.failure = Some(error)
        return Err(error)
      }
      Ok(used) => {
        let remaining : Array[Byte] = []
        for index in used..<self.decoder_buffer.length() {
          remaining.push(self.decoder_buffer[index])
        }
        self.decoder_buffer = remaining
      }
    }
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
