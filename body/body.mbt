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
pub fn SizeHint::lower_bound(self : SizeHint) -> Int {
  self.lower
}

///|
pub fn SizeHint::upper_bound(self : SizeHint) -> Int? {
  self.upper
}

///|
pub fn SizeHint::exact_size(self : SizeHint) -> Int? {
  match self.upper {
    Some(value) if value == self.lower => Some(value)
    _ => None
  }
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
priv suberror BodyStreamEnded derive(Debug)

///|
/// A bounded asynchronous body stream.
///
/// `push` suspends when the configured queue is full, providing backpressure
/// to the protocol reader. `finish` marks a normal end of stream, while
/// `fail` wakes all consumers with the original error.
pub struct BodyStream {
  queue : @aqueue.Queue[Frame]
  hint : SizeHint
  on_data_consumed : async (Int) -> Unit
  pull : (async () -> Frame?)?
  mut finished : Bool
  mut failure : Error?
}

///|
pub fn BodyStream::new(
  capacity? : Int = 8,
  size_hint? : SizeHint = SizeHint::unknown(),
  on_data_consumed? : async (Int) -> Unit = fn(_) { () },
) -> BodyStream {
  if capacity < 1 {
    abort("body stream capacity must be positive")
  }
  {
    queue: Queue(kind=Blocking(capacity)),
    hint: size_hint,
    on_data_consumed,
    pull: None,
    finished: false,
    failure: None,
  }
}

///|
/// Creates a pull-driven stream. Each `next_frame` call drives the supplied
/// protocol reader until one frame or end-of-stream is available.
pub fn BodyStream::from_pull(
  pull : async () -> Frame?,
  size_hint? : SizeHint = SizeHint::unknown(),
) -> BodyStream {
  {
    queue: Queue(kind=Blocking(1)),
    hint: size_hint,
    on_data_consumed: fn(_) { () },
    pull: Some(pull),
    finished: false,
    failure: None,
  }
}

///|
pub async fn BodyStream::push(self : BodyStream, frame : Frame) -> Unit {
  if self.pull is Some(_) {
    raise BodyStreamEnded
  }
  if self.finished {
    raise match self.failure {
      Some(error) => error
      None => BodyStreamEnded
    }
  }
  self.queue.put(frame)
}

///|
/// Attempts to enqueue a frame without suspending. Returns `false` when the
/// bounded queue is full.
pub fn BodyStream::try_push(self : BodyStream, frame : Frame) -> Bool raise {
  if self.pull is Some(_) {
    raise BodyStreamEnded
  }
  if self.finished {
    raise match self.failure {
      Some(error) => error
      None => BodyStreamEnded
    }
  }
  self.queue.try_put(frame)
}

///|
pub fn BodyStream::finish(self : BodyStream) -> Unit {
  if !self.finished {
    self.finished = true
    if self.pull is None {
      self.queue.close(error=BodyStreamEnded)
    }
  }
}

///|
pub fn BodyStream::fail(self : BodyStream, error : Error) -> Unit {
  if !self.finished {
    self.finished = true
    self.failure = Some(error)
    if self.pull is None {
      self.queue.close(error~)
    }
  }
}

///|
pub impl Body for BodyStream with fn next_frame(self) {
  if self.pull is Some(pull) {
    if self.finished {
      return match self.failure {
        Some(error) => raise error
        None => None
      }
    }
    let output = pull() catch {
      error => {
        self.finished = true
        self.failure = Some(error)
        raise error
      }
    }
    if output is None {
      self.finished = true
    }
    return output
  }
  let output = Some(self.queue.get()) catch {
    BodyStreamEnded => None
    error => raise error
  }
  if output is Some(Data(data)) {
    (self.on_data_consumed)(data.length())
  }
  output
}

///|
pub impl Body for BodyStream with fn size_hint(self) {
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
