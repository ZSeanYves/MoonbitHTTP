///|
fn content_coding_token_byte(byte : Byte) -> Bool {
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
fn content_coding_from_token(
  token : BytesView,
) -> Result[ContentCoding, ContentCodingError] {
  let lowered = FixedArray::make(token.length(), b'0')
  for index in 0..<token.length() {
    let byte = token[index]
    if !content_coding_token_byte(byte) {
      return Err(InvalidContentEncoding)
    }
    lowered[index] = if byte >= b'A' && byte <= b'Z' {
      (byte.to_int() + 32).to_byte()
    } else {
      byte
    }
  }
  let name = @utf8.decode(lowered.unsafe_reinterpret_as_bytes()) catch {
    _ => return Err(InvalidContentEncoding)
  }
  match name {
    "identity" => Ok(Identity)
    "gzip" | "x-gzip" => Ok(Gzip)
    "deflate" => Ok(Deflate)
    "br" => Ok(Brotli)
    _ => Err(UnsupportedContentCoding(name))
  }
}

///|
/// Parses all `Content-Encoding` field lines in wire order. The returned
/// sequence is the order in which encodings were applied by the sender.
pub fn parse_content_codings(
  headers : @types.HeaderMap,
  max_codings? : Int = 4,
) -> Result[Array[ContentCoding], ContentCodingError] {
  if max_codings < 1 {
    return Err(InvalidContentCodingLimits)
  }
  let values = headers.get_all_string("content-encoding")
  let codings : Array[ContentCoding] = []
  let mut saw_nonempty = false
  for value in values {
    let bytes = value.bytes
    let mut start = 0
    while start <= bytes.length() {
      let mut end = start
      while end < bytes.length() && bytes[end] != b',' {
        end += 1
      }
      let mut item_start = start
      let mut item_end = end
      while item_start < item_end &&
            (bytes[item_start] == b' ' || bytes[item_start] == b'\t') {
        item_start += 1
      }
      while item_end > item_start &&
            (bytes[item_end - 1] == b' ' || bytes[item_end - 1] == b'\t') {
        item_end -= 1
      }
      if item_start < item_end {
        saw_nonempty = true
        if codings.length() >= max_codings {
          return Err(TooManyContentCodings(max_codings))
        }
        let coding = match
          content_coding_from_token(bytes[item_start:item_end]) {
          Ok(result) => result
          Err(error) => return Err(error)
        }
        codings.push(coding)
      }
      if end == bytes.length() {
        break
      }
      start = end + 1
    }
  }
  if !values.is_empty() && !saw_nonempty {
    Err(InvalidContentEncoding)
  } else {
    Ok(codings)
  }
}
