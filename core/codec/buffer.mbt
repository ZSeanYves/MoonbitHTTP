///|
#derive(Debug, Eq)
pub(all) suberror CodecError {
  NeedMore
  LimitExceeded(kind~ : String, limit~ : Int32)
  Malformed(String)
  UnexpectedEof(String)
}

///|
pub struct Buffer {
  mut bytes : Array[Byte]
  mut start : Int32
  max_bytes : Int32
}

///|
pub fn Buffer::new(max_bytes~ : Int32 = 256 * 1024) -> Buffer {
  { bytes: [], start: 0, max_bytes, }
}

///|
pub fn Buffer::length(self : Buffer) -> Int32 {
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
  if current_length == 0 {
    self.bytes = input.to_array()
    self.start = 0
  } else {
    if self.start > 0 && (self.start >= 4096 || self.start >= current_length) {
      self.bytes = self.bytes[self.start:].to_owned()
      self.start = 0
    }
    self.bytes.append(input.to_array())
  }
  Ok(())
}

///|
pub fn Buffer::peek(self : Buffer) -> Bytes {
  Bytes::from_array(self.bytes[self.start:])
}

///|
/// Copy at most the requested number of unread bytes without consuming them.
pub fn Buffer::peek_prefix(self : Buffer, count : Int32) -> Bytes {
  let count = count.max(0).min(self.length())
  Bytes::from_array(self.bytes[self.start:self.start + count])
}

///|
pub fn Buffer::take(self : Buffer, count : Int32) -> Bytes {
  let count = count.max(0).min(self.length())
  let start = self.start
  self.start += count
  Bytes::from_array(self.bytes[start:self.start])
}

///|
/// Take an owned array for wire APIs whose payload representation is Array.
/// Skip the intermediate immutable Bytes allocation on this path.
#internal(http2_frame)
pub fn Buffer::take_array(self : Buffer, count : Int32) -> Array[Byte] {
  let count = count.max(0).min(self.length())
  let start = self.start
  self.start += count
  self.bytes[start:self.start].to_owned()
}

///|
pub fn Buffer::find_crlf(self : Buffer) -> Int32? {
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
  max_length : Int32,
) -> Result[Bytes, CodecError] {
  match self.find_crlf() {
    None => {
      let pending = self.length()
      // A final CR may be the first byte of a fragmented delimiter.
      let length = if pending > 0 &&
        self.bytes[self.bytes.length() - 1] == b'\r' {
        pending - 1
      } else {
        pending
      }
      if length > max_length {
        Err(LimitExceeded(kind="line", limit=max_length))
      } else {
        Err(NeedMore)
      }
    }
    Some(index) => {
      if index > max_length {
        return Err(LimitExceeded(kind="line", limit=max_length))
      }
      let line = self.take(index)
      self.start += 2
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
