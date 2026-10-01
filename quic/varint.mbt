///|
pub(all) struct QuicVarInt {
  value : Int64
} derive(Eq, Debug, Compare)

///|
pub fn QuicVarInt::new(value : Int64) -> Result[QuicVarInt, QuicError] {
  if value < 0L || value > QUIC_MAX_VARINT {
    return Err(VarIntOverflow)
  }
  Ok({ value, })
}

///|
pub fn QuicVarInt::value(self : QuicVarInt) -> Int64 {
  self.value
}

///|
pub fn QuicVarInt::encoded_length(self : QuicVarInt) -> Int {
  if self.value <= 63L {
    1
  } else if self.value <= 16383L {
    2
  } else if self.value <= 1073741823L {
    4
  } else {
    8
  }
}

///|
pub fn QuicVarInt::encode(self : QuicVarInt) -> Bytes {
  match self.encoded_length() {
    1 => Bytes::from_array([self.value.to_byte()])
    2 =>
      Bytes::from_array([
        ((self.value >> 8) | 0x40L).to_byte(),
        self.value.to_byte(),
      ])
    4 =>
      Bytes::from_array([
        ((self.value >> 24) | 0x80L).to_byte(),
        (self.value >> 16).to_byte(),
        (self.value >> 8).to_byte(),
        self.value.to_byte(),
      ])
    _ =>
      Bytes::from_array([
        ((self.value >> 56) | 0xc0L).to_byte(),
        (self.value >> 48).to_byte(),
        (self.value >> 40).to_byte(),
        (self.value >> 32).to_byte(),
        (self.value >> 24).to_byte(),
        (self.value >> 16).to_byte(),
        (self.value >> 8).to_byte(),
        self.value.to_byte(),
      ])
  }
}

///|
fn quic_varint_length(first : Byte) -> Int {
  match first.to_int() >> 6 {
    0 => 1
    1 => 2
    2 => 4
    _ => 8
  }
}

///|
pub fn quic_decode_varint(
  input : BytesView,
  canonical? : Bool = false,
) -> Result[(QuicVarInt, Int), QuicError] {
  if input.is_empty() {
    return Err(NeedMoreInput)
  }
  let length = quic_varint_length(input[0])
  if input.length() < length {
    return Err(NeedMoreInput)
  }
  let mut value : Int64 = (input[0].to_int() & 0x3f).to_int64()
  for index in 1..<length {
    value = (value << 8) | input[index].to_int().to_int64()
  }
  let result = match QuicVarInt::new(value) {
    Ok(result) => result
    Err(error) => return Err(error)
  }
  if canonical && result.encoded_length() != length {
    return Err(NonCanonicalVarInt)
  }
  Ok((result, length))
}
