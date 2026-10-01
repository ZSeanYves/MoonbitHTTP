///|
priv enum QpackParseError {
  QpackParseNeedMore
  QpackParseMalformed(String)
}

///|
fn qpack_decode_integer(
  input : BytesView,
  prefix_bits : Int,
) -> Result[(Int64, Int), QpackParseError] {
  if input.is_empty() {
    return Err(QpackParseNeedMore)
  }
  if prefix_bits < 1 || prefix_bits > 8 {
    return Err(QpackParseMalformed("invalid QPACK integer prefix"))
  }
  let prefix_max = (1 << prefix_bits) - 1
  let mut value = (input[0].to_int() & prefix_max).to_int64()
  if value < prefix_max.to_int64() {
    return Ok((value, 1))
  }
  let mut offset = 1
  let mut shift = 0
  while offset < input.length() {
    let byte = input[offset].to_int()
    let digit = (byte & 0x7f).to_int64()
    if shift > 56 || digit > (@quic.QUIC_MAX_VARINT - value) >> shift {
      return Err(QpackParseMalformed("QPACK integer overflow"))
    }
    value += digit << shift
    offset += 1
    if (byte & 0x80) == 0 {
      return Ok((value, offset))
    }
    shift += 7
  }
  Err(QpackParseNeedMore)
}

///|
fn qpack_encode_integer(prefix_bits : Int, value : Int64) -> Array[Byte] {
  let prefix_max = (1 << prefix_bits) - 1
  let output : Array[Byte] = []
  if value < prefix_max.to_int64() {
    output.push(value.to_byte())
    return output
  }
  output.push(prefix_max.to_byte())
  let mut remaining = value - prefix_max.to_int64()
  while remaining >= 128L {
    output.push(((remaining & 0x7fL) | 0x80L).to_byte())
    remaining = remaining >> 7
  }
  output.push(remaining.to_byte())
  output
}

///|
fn qpack_decode_string(
  input : BytesView,
  prefix_bits : Int,
  huffman_mask : Int,
  max_decoded_bytes : Int,
) -> Result[(Bytes, Int), QpackParseError] {
  if input.is_empty() {
    return Err(QpackParseNeedMore)
  }
  let huffman = (input[0].to_int() & huffman_mask) != 0
  let (length64, prefix_used) = match qpack_decode_integer(input, prefix_bits) {
    Ok(result) => result
    Err(error) => return Err(error)
  }
  if length64 > max_decoded_bytes.to_int64() ||
    length64 > @int.MAX_VALUE.to_int64() {
    return Err(QpackParseMalformed("QPACK string exceeds configured limit"))
  }
  let length = length64.to_int()
  if prefix_used > input.length() || length > input.length() - prefix_used {
    return Err(QpackParseNeedMore)
  }
  let encoded = input[prefix_used:prefix_used + length].to_owned()
  let decoded = if huffman {
    match @codec.huffman_decode(encoded) {
      Ok(value) => value
      Err(InvalidCode) =>
        return Err(QpackParseMalformed("invalid QPACK Huffman code"))
      Err(UnexpectedEos) =>
        return Err(QpackParseMalformed("QPACK Huffman EOS encountered in data"))
      Err(InvalidPadding) =>
        return Err(QpackParseMalformed("invalid QPACK Huffman EOS padding"))
    }
  } else {
    encoded
  }
  if decoded.length() > max_decoded_bytes {
    return Err(
      QpackParseMalformed("decoded QPACK string exceeds configured limit"),
    )
  }
  Ok((decoded, prefix_used + length))
}

///|
fn qpack_encode_string(
  raw : BytesView,
  prefix_bits : Int,
  huffman_mask : Int,
  leading_bits : Int,
  use_huffman : Bool,
) -> Array[Byte] {
  let raw_bytes = raw.to_owned()
  let (payload, huffman) = if use_huffman {
    let encoded = @codec.huffman_encode(raw_bytes)
    if encoded.length() < raw_bytes.length() {
      (encoded, true)
    } else {
      (raw_bytes, false)
    }
  } else {
    (raw_bytes, false)
  }
  let output = qpack_encode_integer(prefix_bits, payload.length().to_int64())
  output[0] = (output[0].to_int() |
  leading_bits |
  (if huffman { huffman_mask } else { 0 })).to_byte()
  for byte in payload {
    output.push(byte)
  }
  output
}

///|
fn qpack_field_size(field : QpackField) -> Int {
  @utf8.encode(field.name).length() + field.value.length() + 32
}

///|
fn qpack_append(output : Array[Byte], encoded : Array[Byte]) -> Unit {
  for byte in encoded {
    output.push(byte)
  }
}

///|
fn qpack_parse_error(
  error : QpackParseError,
  code : H3ErrorCode,
  context : String,
) -> Http3Error {
  match error {
    QpackParseNeedMore => Http3ConnectionError(code, context + " is truncated")
    QpackParseMalformed(message) =>
      Http3ConnectionError(code, context + ": " + message)
  }
}

///|
fn qpack_decode_name(raw : Bytes) -> Result[String, QpackParseError] {
  let name = @utf8.decode(raw) catch {
    _ => return Err(QpackParseMalformed("field name is not valid UTF-8"))
  }
  let field = { name, value: b"", sensitive: false, }
  match qpack_validate_field(field) {
    Ok(_) => Ok(name)
    Err(_) => Err(QpackParseMalformed("invalid or uppercase field name"))
  }
}

///|
pub fn qpack_section_acknowledgment(
  stream_id : Int64,
) -> Result[Bytes, Http3Error] {
  if stream_id < 0L || stream_id > @quic.QUIC_MAX_VARINT {
    return Err(
      Http3ConnectionError(QpackDecoderStreamError, "invalid stream ID"),
    )
  }
  let encoded = qpack_encode_integer(7, stream_id)
  encoded[0] = (encoded[0].to_int() | 0x80).to_byte()
  Ok(Bytes::from_array(encoded))
}

///|
pub fn qpack_stream_cancellation(
  stream_id : Int64,
) -> Result[Bytes, Http3Error] {
  if stream_id < 0L || stream_id > @quic.QUIC_MAX_VARINT {
    return Err(
      Http3ConnectionError(QpackDecoderStreamError, "invalid stream ID"),
    )
  }
  let encoded = qpack_encode_integer(6, stream_id)
  encoded[0] = (encoded[0].to_int() | 0x40).to_byte()
  Ok(Bytes::from_array(encoded))
}

///|
pub fn qpack_insert_count_increment(
  increment : Int64,
) -> Result[Bytes, Http3Error] {
  if increment <= 0L || increment > @quic.QUIC_MAX_VARINT {
    return Err(
      Http3ConnectionError(
        QpackDecoderStreamError,
        "invalid insert count increment",
      ),
    )
  }
  Ok(Bytes::from_array(qpack_encode_integer(6, increment)))
}
