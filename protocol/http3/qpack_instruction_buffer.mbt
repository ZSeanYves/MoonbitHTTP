///|
/// Inspect framing without copying or decoding partial literal strings. Each
/// instruction contains at most two strings and bounded-width integers, so a
/// byte-at-a-time feed does constant framing work until the instruction ends.
fn qpack_buffer_integer(
  input : Array[Byte],
  offset : Int,
  prefix_bits : Int,
) -> Result[(Int64, Int), QpackParseError] {
  if offset >= input.length() {
    return Err(QpackParseNeedMore)
  }
  let prefix_max = (1 << prefix_bits) - 1
  let mut value = (input[offset].to_int() & prefix_max).to_int64()
  let mut cursor = offset + 1
  if value < prefix_max.to_int64() {
    return Ok((value, cursor))
  }
  let mut shift = 0
  while cursor < input.length() {
    let byte = input[cursor].to_int()
    let digit = (byte & 0x7f).to_int64()
    if shift > 56 || digit > (@quic.QUIC_MAX_VARINT - value) >> shift {
      return Err(QpackParseMalformed("QPACK integer overflow"))
    }
    value += digit << shift
    cursor += 1
    if (byte & 0x80) == 0 {
      return Ok((value, cursor))
    }
    shift += 7
  }
  Err(QpackParseNeedMore)
}

///|
fn qpack_buffer_string_end(
  input : Array[Byte],
  offset : Int,
  prefix_bits : Int,
  max_string_bytes : Int,
) -> Result[Int, QpackParseError] {
  let (length, start) = match qpack_buffer_integer(input, offset, prefix_bits) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if length > max_string_bytes.to_int64() {
    return Err(QpackParseMalformed("QPACK string exceeds configured limit"))
  }
  if length > (input.length() - start).to_int64() {
    return Err(QpackParseNeedMore)
  }
  Ok(start + length.to_int())
}

///|
fn qpack_instruction_length(
  input : Array[Byte],
  offset : Int,
  encoder_stream : Bool,
  max_string_bytes : Int,
) -> Result[Int, QpackParseError] {
  let first = input[offset].to_int()
  let end = if !encoder_stream {
    match
      qpack_buffer_integer(
        input,
        offset,
        if (first & 0x80) != 0 {
          7
        } else {
          6
        },
      ) {
      Ok((_, end)) => end
      Err(error) => return Err(error)
    }
  } else if (first & 0x80) != 0 {
    let name_end = match qpack_buffer_integer(input, offset, 6) {
      Ok((_, end)) => end
      Err(error) => return Err(error)
    }
    match qpack_buffer_string_end(input, name_end, 7, max_string_bytes) {
      Ok(end) => end
      Err(error) => return Err(error)
    }
  } else if (first & 0x40) != 0 {
    let name_end = match
      qpack_buffer_string_end(input, offset, 5, max_string_bytes) {
      Ok(end) => end
      Err(error) => return Err(error)
    }
    match qpack_buffer_string_end(input, name_end, 7, max_string_bytes) {
      Ok(end) => end
      Err(error) => return Err(error)
    }
  } else {
    match qpack_buffer_integer(input, offset, 5) {
      Ok((_, end)) => end
      Err(error) => return Err(error)
    }
  }
  Ok(end - offset)
}
