///|
priv enum BodyState {
  BodyNone
  BodyFixed(Int)
  BodyChunkSize
  BodyChunkData(Int)
  BodyChunkCrlf
  BodyTrailers(@types.HeaderMap, Int, Int)
  BodyClose
  BodyEnd
}

///|
priv struct BodyDecoder {
  mut state : BodyState
  mut total : Int
  limits : @types.Limits
  mut eof : Bool
}

///|
priv enum BodyEvent {
  Data(Bytes)
  Trailers(@types.HeaderMap)
  End
}

///|
fn BodyDecoder::new(
  framing : BodyFraming,
  limits : @types.Limits,
) -> BodyDecoder {
  let state = match framing {
    NoBody => BodyEnd
    ContentLength(0) => BodyEnd
    ContentLength(size) => BodyFixed(size)
    Chunked => BodyChunkSize
    CloseDelimited => BodyClose
  }
  { state, total: 0, limits, eof: false, }
}

///|
fn BodyDecoder::finish_input(self : BodyDecoder) -> Unit {
  self.eof = true
}

///|
fn http1_is_tchar(byte : Byte) -> Bool {
  let value = byte.to_int()
  (value >= 48 && value <= 57) ||
  (value >= 65 && value <= 90) ||
  (value >= 97 && value <= 122) ||
  byte == b'!' ||
  byte == b'#' ||
  byte == b'$' ||
  byte == b'%' ||
  byte == b'&' ||
  byte == b'\'' ||
  byte == b'*' ||
  byte == b'+' ||
  byte == b'-' ||
  byte == b'.' ||
  byte == b'^' ||
  byte == b'_' ||
  byte == b'`' ||
  byte == b'|' ||
  byte == b'~'
}

///|
/// RFC 9112 chunk extensions are intentionally parsed rather than ignored.
/// This prevents malformed extension bytes from becoming a second framing
/// interpretation in a downstream proxy.
fn parse_chunk_extension(
  input : BytesView,
  start : Int,
) -> Result[Unit, Http1Error] {
  let mut index = start
  while index < input.length() {
    while index < input.length() &&
          (input[index] == b' ' || input[index] == b'\t') {
      index += 1
    }
    if index >= input.length() || input[index] != b';' {
      return Err(InvalidFraming("invalid chunk extension"))
    }
    index += 1
    while index < input.length() &&
          (input[index] == b' ' || input[index] == b'\t') {
      index += 1
    }
    let name_start = index
    while index < input.length() && http1_is_tchar(input[index]) {
      index += 1
    }
    if index == name_start {
      return Err(InvalidFraming("invalid chunk extension name"))
    }
    while index < input.length() &&
          (input[index] == b' ' || input[index] == b'\t') {
      index += 1
    }
    if index < input.length() && input[index] == b'=' {
      index += 1
      while index < input.length() &&
            (input[index] == b' ' || input[index] == b'\t') {
        index += 1
      }
      if index >= input.length() {
        return Err(InvalidFraming("chunk extension value is missing"))
      }
      if input[index] == b'"' {
        index += 1
        let mut closed = false
        while index < input.length() {
          let byte = input[index]
          if byte == b'\\' {
            if index + 1 >= input.length() || input[index + 1] < 0x20 {
              return Err(InvalidFraming("invalid quoted chunk extension"))
            }
            index += 2
          } else if byte == b'"' {
            index += 1
            closed = true
            break
          } else if byte < 0x20 || byte == 0x7f {
            return Err(InvalidFraming("invalid quoted chunk extension"))
          } else {
            index += 1
          }
        }
        if !closed {
          return Err(InvalidFraming("unterminated chunk extension"))
        }
      } else {
        let value_start = index
        while index < input.length() && http1_is_tchar(input[index]) {
          index += 1
        }
        if index == value_start {
          return Err(InvalidFraming("invalid chunk extension value"))
        }
      }
      while index < input.length() &&
            (input[index] == b' ' || input[index] == b'\t') {
        index += 1
      }
    }
  }
  Ok(())
}

///|
fn parse_hex_size(line : Bytes) -> Result[Int, Http1Error] {
  let mut size = 0
  let mut digits = 0
  for byte in line {
    if byte == b';' {
      break
    }
    if byte == b' ' || byte == b'\t' {
      // OWS before the first extension delimiter is permitted.
      break
    }
    let value = if byte >= b'0' && byte <= b'9' {
      byte.to_int() - 48
    } else if byte >= b'a' && byte <= b'f' {
      byte.to_int() - 87
    } else if byte >= b'A' && byte <= b'F' {
      byte.to_int() - 55
    } else {
      return Err(InvalidFraming("invalid chunk size"))
    }
    digits += 1
    if size > (0x7fffffff - value) / 16 {
      return Err(InvalidFraming("chunk size overflow"))
    }
    size = size * 16 + value
  }
  if digits == 0 {
    Err(InvalidFraming("empty chunk size"))
  } else {
    let mut end = digits
    while end < line.length() && (line[end] == b' ' || line[end] == b'\t') {
      end += 1
    }
    if end < line.length() {
      if line[end] != b';' {
        return Err(InvalidFraming("invalid chunk size extension"))
      }
      match parse_chunk_extension(line, end) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
    }
    Ok(size)
  }
}

///|
fn BodyDecoder::next(
  self : BodyDecoder,
  buffer : @codec.Buffer,
) -> Result[BodyEvent?, Http1Error] {
  match self.state {
    BodyNone => Ok(None)
    BodyEnd => {
      self.state = BodyNone
      Ok(Some(End))
    }
    BodyFixed(remaining) => {
      if remaining == 0 {
        self.state = BodyEnd
        return self.next(buffer)
      }
      if buffer.length() == 0 {
        if self.eof {
          return Err(UnexpectedEof("fixed-length body"))
        }
        return Ok(None)
      }
      let count = if buffer.length() < remaining {
        buffer.length()
      } else {
        remaining
      }
      let data = buffer.take(count)
      self.total += count
      self.state = if count == remaining {
        BodyEnd
      } else {
        BodyFixed(remaining - count)
      }
      Ok(Some(Data(data)))
    }
    BodyChunkSize => {
      let line = match buffer.read_line(self.limits.max_header_line) {
        Ok(line) => line
        Err(NeedMore) => {
          if self.eof {
            return Err(UnexpectedEof("chunk size"))
          }
          return Ok(None)
        }
        Err(_) => return Err(LimitExceeded("chunk size line"))
      }
      let size = match parse_hex_size(line) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if self.total > self.limits.max_body_bytes ||
        size > self.limits.max_body_bytes - self.total {
        return Err(LimitExceeded("message body"))
      }
      self.state = if size == 0 {
        BodyTrailers(@types.HeaderMap::new(), 0, 0)
      } else {
        BodyChunkData(size)
      }
      self.next(buffer)
    }
    BodyChunkData(remaining) => {
      if buffer.length() == 0 {
        if self.eof {
          return Err(UnexpectedEof("chunk data"))
        }
        return Ok(None)
      }
      let count = if buffer.length() < remaining {
        buffer.length()
      } else {
        remaining
      }
      let data = buffer.take(count)
      self.total += count
      self.state = if count == remaining {
        BodyChunkCrlf
      } else {
        BodyChunkData(remaining - count)
      }
      Ok(Some(Data(data)))
    }
    BodyChunkCrlf => {
      if buffer.length() < 2 {
        if self.eof {
          return Err(UnexpectedEof("chunk terminator"))
        }
        return Ok(None)
      }
      if buffer.take(2) != b"\r\n" {
        return Err(InvalidFraming("chunk data is not followed by CRLF"))
      }
      self.state = BodyChunkSize
      self.next(buffer)
    }
    BodyTrailers(headers, count, bytes) => {
      let line = match buffer.read_line(self.limits.max_header_line) {
        Ok(line) => line
        Err(NeedMore) => {
          if self.eof {
            return Err(UnexpectedEof("chunk trailers"))
          }
          return Ok(None)
        }
        Err(_) => return Err(LimitExceeded("trailer line"))
      }
      if line.is_empty() {
        match http1_validate_trailer_fields(headers) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
        self.state = BodyEnd
        if headers.is_empty() {
          self.next(buffer)
        } else {
          Ok(Some(Trailers(headers)))
        }
      } else {
        if count + 1 > self.limits.max_header_count ||
          bytes + line.length() + 2 > self.limits.max_header_bytes {
          return Err(LimitExceeded("trailers"))
        }
        match decode_header_line(line, headers) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
        self.state = BodyTrailers(headers, count + 1, bytes + line.length() + 2)
        self.next(buffer)
      }
    }
    BodyClose => {
      if buffer.length() > 0 {
        let count = buffer.length()
        if self.total > self.limits.max_body_bytes ||
          count > self.limits.max_body_bytes - self.total {
          return Err(LimitExceeded("close-delimited body"))
        }
        let data = buffer.take(count)
        self.total += count
        return Ok(Some(Data(data)))
      }
      if self.eof {
        self.state = BodyEnd
        self.next(buffer)
      } else {
        Ok(None)
      }
    }
  }
}
