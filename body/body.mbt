///|
pub(all) enum Frame {
  Data(Bytes)
  Trailers(@types.HeaderMap)
}

///|
pub(all) struct SizeHint {
  lower : Int
  upper : Int?
}

///|
pub fn SizeHint::exact(size : Int) -> SizeHint {
  { lower: size, upper: Some(size) }
}

///|
pub fn SizeHint::unknown() -> SizeHint {
  { lower: 0, upper: None }
}

///|
pub(open) trait Body {
  async fn next_frame(Self) -> Frame?
  fn size_hint(Self) -> SizeHint
}

///|
pub struct EmptyBody(Unit)

///|
pub fn EmptyBody::new() -> EmptyBody {
  EmptyBody(())
}

///|
pub impl Body for EmptyBody with fn next_frame(_self) {
  None
}

///|
pub impl Body for EmptyBody with fn size_hint(_self) {
  SizeHint::exact(0)
}

///|
pub struct FullBody {
  data : Bytes
  mut sent : Bool
}

///|
pub fn FullBody::new(data : Bytes) -> FullBody {
  { data, sent: false }
}

///|
pub impl Body for FullBody with fn next_frame(self) {
  if self.sent {
    None
  } else {
    self.sent = true
    Some(Data(self.data))
  }
}

///|
pub impl Body for FullBody with fn size_hint(self) {
  SizeHint::exact(self.data.length())
}

///|
pub struct QueueBody {
  frames : Array[Frame]
  mut cursor : Int
  hint : SizeHint
}

///|
pub fn QueueBody::new(frames : Array[Frame]) -> QueueBody {
  let mut size = 0
  let mut exact = true
  for frame in frames {
    match frame {
      Data(data) => size += data.length()
      Trailers(_) => exact = false
    }
  }
  {
    frames,
    cursor: 0,
    hint: if exact {
      SizeHint::exact(size)
    } else {
      { lower: size, upper: None }
    },
  }
}

///|
pub impl Body for QueueBody with fn next_frame(self) {
  if self.cursor >= self.frames.length() {
    None
  } else {
    let frame = self.frames[self.cursor]
    self.cursor += 1
    Some(frame)
  }
}

///|
pub impl Body for QueueBody with fn size_hint(self) {
  self.hint
}

///|
pub(all) suberror BodyLimitExceeded {
  BodyLimitExceeded(limit~ : Int)
} derive(Debug, Eq)

///|
pub async fn[B : Body] collect(
  body : B,
  max_bytes? : Int = 16 * 1024 * 1024,
) -> (Bytes, @types.HeaderMap?) {
  let data : Array[Byte] = []
  let mut trailers : @types.HeaderMap? = None
  while body.next_frame() is Some(frame) {
    match frame {
      Data(chunk) => {
        if data.length() + chunk.length() > max_bytes {
          raise BodyLimitExceeded(limit=max_bytes)
        }
        for byte in chunk {
          data.push(byte)
        }
      }
      Trailers(value) => trailers = Some(value)
    }
  }
  (Bytes::from_array(data), trailers)
}
