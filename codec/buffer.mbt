///|
pub(all) suberror CodecError {
  NeedMore
  LimitExceeded(kind~ : String, limit~ : Int)
  Malformed(String)
  UnexpectedEof(String)
} derive(Debug, Eq)

///|
pub struct Buffer {
  mut bytes : Array[Byte]
  max_bytes : Int
}

///|
pub fn Buffer::new(max_bytes? : Int = 256 * 1024) -> Buffer {
  { bytes: [], max_bytes }
}

///|
pub fn Buffer::length(self : Buffer) -> Int {
  self.bytes.length()
}

///|
pub fn Buffer::feed(
  self : Buffer,
  input : BytesView,
) -> Result[Unit, CodecError] {
  if self.bytes.length() + input.length() > self.max_bytes {
    return Err(LimitExceeded(kind="connection buffer", limit=self.max_bytes))
  }
  for byte in input {
    self.bytes.push(byte)
  }
  Ok(())
}

///|
pub fn Buffer::peek(self : Buffer) -> Bytes {
  Bytes::from_array(self.bytes)
}

///|
pub fn Buffer::take(self : Buffer, count : Int) -> Bytes {
  let count = if count < self.bytes.length() {
    count
  } else {
    self.bytes.length()
  }
  let out : Array[Byte] = []
  let rest : Array[Byte] = []
  for i in 0..<self.bytes.length() {
    if i < count {
      out.push(self.bytes[i])
    } else {
      rest.push(self.bytes[i])
    }
  }
  self.bytes = rest
  Bytes::from_array(out)
}

///|
pub fn Buffer::find_crlf(self : Buffer) -> Int? {
  for i in 1..<self.bytes.length() {
    if self.bytes[i - 1] == b'\r' && self.bytes[i] == b'\n' {
      return Some(i - 1)
    }
  }
  None
}

///|
pub fn Buffer::read_line(
  self : Buffer,
  max_length : Int,
) -> Result[Bytes, CodecError] {
  match self.find_crlf() {
    None =>
      if self.bytes.length() > max_length {
        Err(LimitExceeded(kind="line", limit=max_length))
      } else {
        Err(NeedMore)
      }
    Some(index) => {
      if index > max_length {
        return Err(LimitExceeded(kind="line", limit=max_length))
      }
      let line = self.take(index)
      ignore(self.take(2))
      Ok(line)
    }
  }
}

///|
pub fn Buffer::starts_with(self : Buffer, prefix : BytesView) -> Bool {
  if self.bytes.length() < prefix.length() {
    return false
  }
  for i in 0..<prefix.length() {
    if self.bytes[i] != prefix[i] {
      return false
    }
  }
  true
}
