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
  priv data : Bytes
  priv mut sent : Bool
}

///|
pub fn FullBody::new(data : Bytes) -> FullBody {
  { data, sent: false, }
}

///|
pub impl Body for FullBody with fn next_frame(self) {
  if self.sent {
    None
  } else {
    self.sent = true
    if self.data.is_empty() {
      None
    } else {
      Some(Data(self.data))
    }
  }
}

///|
pub impl Body for FullBody with fn size_hint(self) {
  SizeHint::exact(self.data.length())
}

///|
pub struct QueueBody {
  priv frames : Array[Frame]
  priv mut cursor : Int
  priv hint : SizeHint
  priv mut trailers_seen : Bool
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
    frames: frames.copy(),
    cursor: 0,
    hint: if exact {
      SizeHint::exact(size)
    } else {
      { lower: size, upper: None, }
    },
    trailers_seen: false,
  }
}

///|
pub impl Body for QueueBody with fn next_frame(self) {
  while self.cursor < self.frames.length() {
    let frame = self.frames[self.cursor]
    self.cursor += 1
    match validate_frame(frame, self.trailers_seen) {
      Err(error) => raise error
      Ok(SkipFrame) => continue
      Ok(DeliverFrame(trailers_seen)) => {
        self.trailers_seen = trailers_seen
        return Some(frame)
      }
    }
  }
  None
}

///|
pub impl Body for QueueBody with fn size_hint(self) {
  self.hint
}
