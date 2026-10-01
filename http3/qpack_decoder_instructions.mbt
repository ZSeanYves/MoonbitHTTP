///|
fn QpackDecoder::parse_encoder_instruction(
  self : QpackDecoder,
) -> Result[Int, QpackParseError] {
  if self.encoder_buffer.is_empty() {
    return Err(QpackParseNeedMore)
  }
  let input = Bytes::from_array(self.encoder_buffer)
  let first = input[0].to_int()
  if (first & 0x80) != 0 {
    let is_static = (first & 0x40) != 0
    let (index, name_used) = match qpack_decode_integer(input, 6) {
      Ok(result) => result
      Err(error) => return Err(error)
    }
    let name = if is_static {
      match qpack_static_field(index) {
        Some(field) => field.name
        None => return Err(QpackParseMalformed("invalid static name index"))
      }
    } else {
      match self.relative_field(index) {
        Some(field) => field.name
        None => return Err(QpackParseMalformed("invalid dynamic name index"))
      }
    }
    let (value, value_used) = match
      qpack_decode_string(
        input[name_used:],
        7,
        0x80,
        self.limits.max_decoded_field_section_bytes,
      ) {
      Ok(result) => result
      Err(error) => return Err(error)
    }
    match self.insert(name, value) {
      Ok(_) => Ok(name_used + value_used)
      Err(Http3ConnectionError(_, message)) => Err(QpackParseMalformed(message))
      Err(_) => Err(QpackParseMalformed("dynamic table insertion failed"))
    }
  } else if (first & 0xc0) == 0x40 {
    let (name_bytes, name_used) = match
      qpack_decode_string(
        input,
        5,
        0x20,
        self.limits.max_decoded_field_section_bytes,
      ) {
      Ok(result) => result
      Err(error) => return Err(error)
    }
    let name = match qpack_decode_name(name_bytes) {
      Ok(result) => result
      Err(error) => return Err(error)
    }
    let (value, value_used) = match
      qpack_decode_string(
        input[name_used:],
        7,
        0x80,
        self.limits.max_decoded_field_section_bytes,
      ) {
      Ok(result) => result
      Err(error) => return Err(error)
    }
    match self.insert(name, value) {
      Ok(_) => Ok(name_used + value_used)
      Err(Http3ConnectionError(_, message)) => Err(QpackParseMalformed(message))
      Err(_) => Err(QpackParseMalformed("dynamic table insertion failed"))
    }
  } else if (first & 0xe0) == 0x20 {
    let (capacity, used) = match qpack_decode_integer(input, 5) {
      Ok(result) => result
      Err(error) => return Err(error)
    }
    match self.set_capacity(capacity) {
      Ok(_) => Ok(used)
      Err(Http3ConnectionError(_, message)) => Err(QpackParseMalformed(message))
      Err(_) => Err(QpackParseMalformed("invalid dynamic table capacity"))
    }
  } else {
    let (index, used) = match qpack_decode_integer(input, 5) {
      Ok(result) => result
      Err(error) => return Err(error)
    }
    let field = match self.relative_field(index) {
      Some(value) => value
      None => return Err(QpackParseMalformed("invalid Duplicate index"))
    }
    match self.insert(field.name, field.value) {
      Ok(_) => Ok(used)
      Err(Http3ConnectionError(_, message)) => Err(QpackParseMalformed(message))
      Err(_) => Err(QpackParseMalformed("dynamic table duplication failed"))
    }
  }
}

///|
pub fn QpackDecoder::feed_encoder_stream(
  self : QpackDecoder,
  bytes : BytesView,
) -> Result[Unit, Http3Error] {
  if self.failure is Some(error) {
    return Err(error)
  }
  if self.encoder_buffer.length() > self.limits.max_instruction_buffer_bytes ||
    bytes.length() >
    self.limits.max_instruction_buffer_bytes - self.encoder_buffer.length() {
    let error = Http3LimitExceeded(
      "QPACK encoder instruction buffer",
      self.limits.max_instruction_buffer_bytes,
    )
    self.failure = Some(error)
    return Err(error)
  }
  h3_append_bytes(self.encoder_buffer, bytes)
  while !self.encoder_buffer.is_empty() {
    match self.parse_encoder_instruction() {
      Err(QpackParseNeedMore) => return Ok(())
      Err(error) => {
        let error = qpack_parse_error(
          error,
          QpackEncoderStreamError,
          "QPACK encoder instruction",
        )
        self.failure = Some(error)
        return Err(error)
      }
      Ok(used) => {
        let remaining : Array[Byte] = []
        for index in used..<self.encoder_buffer.length() {
          remaining.push(self.encoder_buffer[index])
        }
        self.encoder_buffer = remaining
      }
    }
  }
  Ok(())
}

///|
pub fn QpackDecoder::finish_encoder_stream(
  self : QpackDecoder,
) -> Result[Unit, Http3Error] {
  if self.failure is Some(error) {
    return Err(error)
  }
  if !self.encoder_buffer.is_empty() {
    let error = Http3ConnectionError(
      QpackEncoderStreamError,
      "QPACK encoder stream ended mid-instruction",
    )
    self.failure = Some(error)
    return Err(error)
  }
  Ok(())
}
