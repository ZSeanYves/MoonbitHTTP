///|
/// The outgoing HTTP/1 body state shared by client and server drivers.
/// A rejected operation does not consume bytes or change framing state.
pub struct BodyEncoder {
  priv framing : BodyFraming
  priv mut remaining : Int?
  priv mut ended : Bool
}

///|
pub fn BodyEncoder::new(
  framing : BodyFraming,
) -> Result[BodyEncoder, Http1Error] {
  if framing is ContentLength(size) && size < 0 {
    return Err(InvalidFraming("negative content-length"))
  }
  Ok({
    framing,
    remaining: match framing {
      ContentLength(size) => Some(size)
      _ => None
    },
    ended: false,
  })
}

///|
pub fn BodyEncoder::data(
  self : BodyEncoder,
  bytes : Bytes,
) -> Result[Bytes, Http1Error] {
  guard !self.ended else { return Err(InvalidFraming("body data follows end")) }
  if self.remaining is Some(remaining) && bytes.length() > remaining {
    return Err(InvalidFraming("body exceeds content-length"))
  }
  let encoded = match encode_body_data(bytes, self.framing) {
    Ok(encoded) => encoded
    Err(error) => return Err(error)
  }
  if self.remaining is Some(remaining) {
    self.remaining = Some(remaining - bytes.length())
  }
  Ok(encoded)
}

///|
pub fn BodyEncoder::trailers(
  self : BodyEncoder,
  fields : @types.HeaderMap,
) -> Result[Bytes, Http1Error] {
  guard !self.ended else { return Err(InvalidFraming("duplicate body end")) }
  if self.remaining is Some(remaining) && remaining != 0 {
    return Err(InvalidFraming("body shorter than content-length"))
  }
  let encoded = match encode_body_end(self.framing, trailers=fields) {
    Ok(encoded) => encoded
    Err(error) => return Err(error)
  }
  self.ended = true
  Ok(encoded)
}

///|
pub fn BodyEncoder::finish(self : BodyEncoder) -> Result[Bytes, Http1Error] {
  if self.remaining is Some(remaining) && remaining != 0 {
    return Err(InvalidFraming("body shorter than content-length"))
  }
  if self.ended {
    return Ok(b"")
  }
  let encoded = match encode_body_end(self.framing) {
    Ok(encoded) => encoded
    Err(error) => return Err(error)
  }
  self.ended = true
  Ok(encoded)
}
