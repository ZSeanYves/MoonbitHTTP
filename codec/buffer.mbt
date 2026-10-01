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
  mut start : Int
  max_bytes : Int
}

///|
pub fn Buffer::new(max_bytes? : Int = 256 * 1024) -> Buffer {
  { bytes: [], start: 0, max_bytes, }
}

///|
pub fn Buffer::length(self : Buffer) -> Int {
  self.bytes.length() - self.start
}

///|
pub fn Buffer::feed(
  self : Buffer,
  input : BytesView,
) -> Result[Unit, CodecError] {
  let current_length = self.length()
  if self.max_bytes < current_length ||
    input.length() > self.max_bytes - current_length {
    return Err(LimitExceeded(kind="connection buffer", limit=self.max_bytes))
  }
  // Consumption advances `start` instead of copying the unread tail. Compact
  // only after enough progress to keep repeated small takes amortized linear.
  if self.start == self.bytes.length() {
    self.bytes = []
    self.start = 0
  } else if self.start > 0 &&
    (self.start >= 4096 || self.start * 2 >= self.bytes.length()) {
    let compacted : Array[Byte] = []
    for index in self.start..<self.bytes.length() {
      compacted.push(self.bytes[index])
    }
    self.bytes = compacted
    self.start = 0
  }
  for byte in input {
    self.bytes.push(byte)
  }
  Ok(())
}

///|
pub fn Buffer::peek(self : Buffer) -> Bytes {
  let out : Array[Byte] = []
  for index in self.start..<self.bytes.length() {
    out.push(self.bytes[index])
  }
  Bytes::from_array(out)
}

///|
pub fn Buffer::take(self : Buffer, count : Int) -> Bytes {
  let count = count.max(0).min(self.length())
  let out : Array[Byte] = []
  for index in self.start..<(self.start + count) {
    out.push(self.bytes[index])
  }
  self.start += count
  Bytes::from_array(out)
}

///|
pub fn Buffer::find_crlf(self : Buffer) -> Int? {
  for i in (self.start + 1)..<self.bytes.length() {
    if self.bytes[i - 1] == b'\r' && self.bytes[i] == b'\n' {
      return Some(i - self.start - 1)
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
  if self.length() < prefix.length() {
    return false
  }
  for i in 0..<prefix.length() {
    if self.bytes[self.start + i] != prefix[i] {
      return false
    }
  }
  true
}
