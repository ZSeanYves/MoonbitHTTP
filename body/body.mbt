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
  { lower: size, upper: Some(size), }
}

///|
pub fn SizeHint::unknown() -> SizeHint {
  { lower: 0, upper: None, }
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
  fn cancel(Self, Error) -> Unit = _
}

///|
/// The default cancellation hook is intentionally a no-op for compatibility
/// with bodies that do not own asynchronous resources. Resource-owning bodies
/// should override it so consumers such as `collect` can stop upstream work.
impl Body with fn cancel(_self, _error) {
  ()
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
  frames : Array[Frame]
  mut cursor : Int
  hint : SizeHint
  mut trailers_seen : Bool
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

///|
priv suberror BodyStreamEnded derive(Debug)

///|
/// Stable body state errors. These errors describe violations of the body
/// frame contract and never include body bytes or sensitive header values.
pub(all) suberror BodyError {
  DataAfterTrailers
  DuplicateTrailers
  InvalidLimit(Int)
  Cancelled
} derive(Debug, Eq)

///|
priv enum FrameDisposition {
  SkipFrame
  DeliverFrame(Bool)
}

///|
fn validate_frame(
  frame : Frame,
  trailers_seen : Bool,
) -> Result[FrameDisposition, BodyError] {
  match frame {
    Data(data) =>
      if trailers_seen {
        Err(DataAfterTrailers)
      } else if data.is_empty() {
        Ok(SkipFrame)
      } else {
        Ok(DeliverFrame(false))
      }
    Trailers(_) =>
      if trailers_seen {
        Err(DuplicateTrailers)
      } else {
        Ok(DeliverFrame(true))
      }
  }
}

///|
/// A bounded asynchronous body stream.
///
/// `push` suspends when the configured queue is full, providing backpressure
/// to the protocol reader. `finish` marks a normal end of stream, while
/// `fail` wakes all consumers with the original error.
pub struct BodyStream {
  queue : @aqueue.Queue[Frame]
  space_available : @aqueue.Queue[Unit]
  hint : SizeHint
  on_data_consumed : async (Int) -> Unit
  on_terminate : (Error?) -> Unit
  pull : (async () -> Frame?)?
  mut finished : Bool
  mut failure : Error?
  mut trailers_seen : Bool
}

///|
fn body_stream_new_unchecked(
  capacity : Int,
  size_hint : SizeHint,
  on_data_consumed : async (Int) -> Unit,
  on_terminate : (Error?) -> Unit,
) -> BodyStream {
  {
    queue: Queue(kind=Blocking(capacity)),
    // A wake-up is a level signal, not an event log. One token is enough to
    // release a blocked producer, and bounding this queue prevents consumers
    // from accumulating one stale token per body frame.
    space_available: Queue(kind=Blocking(1)),
    hint: size_hint,
    on_data_consumed,
    on_terminate,
    pull: None,
    finished: false,
    failure: None,
    trailers_seen: false,
  }
}

///|
pub fn BodyStream::try_new(
  capacity? : Int = 8,
  size_hint? : SizeHint = SizeHint::unknown(),
  on_data_consumed? : async (Int) -> Unit = fn(_) { () },
  on_terminate? : (Error?) -> Unit = fn(_) { () },
) -> Result[BodyStream, BodyError] {
  if capacity < 1 {
    return Err(InvalidLimit(capacity))
  }
  if size_hint.lower < 0 ||
    (size_hint.upper is Some(upper) && upper < size_hint.lower) {
    return Err(InvalidLimit(size_hint.lower))
  }
  Ok(
    body_stream_new_unchecked(
      capacity, size_hint, on_data_consumed, on_terminate,
    ),
  )
}

///|
/// Compatibility constructor. New code that accepts caller configuration
/// should use `try_new`; this wrapper aborts only for invalid local arguments.
pub fn BodyStream::new(
  capacity? : Int = 8,
  size_hint? : SizeHint = SizeHint::unknown(),
  on_data_consumed? : async (Int) -> Unit = fn(_) { () },
  on_terminate? : (Error?) -> Unit = fn(_) { () },
) -> BodyStream {
  match
    BodyStream::try_new(capacity~, size_hint~, on_data_consumed~, on_terminate~) {
    Ok(stream) => stream
    Err(_) => abort("invalid body stream configuration")
  }
}

///|
/// Creates a pull-driven stream. Each `next_frame` call drives the supplied
/// protocol reader until one frame or end-of-stream is available.
pub fn BodyStream::from_pull(
  pull : async () -> Frame?,
  size_hint? : SizeHint = SizeHint::unknown(),
  on_data_consumed? : async (Int) -> Unit = fn(_) { () },
  on_terminate? : (Error?) -> Unit = fn(_) { () },
) -> BodyStream {
  {
    queue: Queue(kind=Blocking(1)),
    space_available: Queue(kind=Blocking(1)),
    hint: size_hint,
    on_data_consumed,
    on_terminate,
    pull: Some(pull),
    finished: false,
    failure: None,
    trailers_seen: false,
  }
}

///|
fn BodyStream::terminal_error(self : BodyStream) -> Error {
  match self.failure {
    Some(error) => error
    None => BodyStreamEnded
  }
}

///|
fn BodyStream::terminate(
  self : BodyStream,
  error : Error?,
  clear : Bool,
) -> Unit {
  if self.finished {
    return
  }
  self.finished = true
  self.failure = error
  if self.pull is None {
    let queue_error = error.unwrap_or(BodyStreamEnded)
    self.queue.close(error=queue_error, clear~)
    self.space_available.close(error=queue_error, clear=true)
  }
  (self.on_terminate)(error)
}

///|
pub async fn BodyStream::push(self : BodyStream, frame : Frame) -> Unit {
  if self.pull is Some(_) {
    raise self.terminal_error()
  }
  match validate_frame(frame, self.trailers_seen) {
    Err(error) => raise error
    Ok(SkipFrame) => return
    Ok(DeliverFrame(_)) => ()
  }
  if self.finished {
    raise self.terminal_error()
  }
  errdefer self.cancel(BodyError::Cancelled)
  while true {
    if self.finished {
      raise self.terminal_error()
    }
    if self.queue.try_put(frame) {
      if frame is Trailers(_) {
        self.trailers_seen = true
        self.finish()
      }
      return
    }
    self.space_available.get()
  }
}

///|
/// Attempts to enqueue a frame without suspending. Returns `false` when the
/// bounded queue is full.
pub fn BodyStream::try_push(self : BodyStream, frame : Frame) -> Bool raise {
  if self.pull is Some(_) {
    raise self.terminal_error()
  }
  match validate_frame(frame, self.trailers_seen) {
    Err(error) => raise error
    Ok(SkipFrame) => return true
    Ok(DeliverFrame(_)) => ()
  }
  if self.finished {
    raise self.terminal_error()
  }
  if self.queue.try_put(frame) {
    if frame is Trailers(_) {
      self.trailers_seen = true
      self.finish()
    }
    true
  } else {
    false
  }
}

///|
pub fn BodyStream::finish(self : BodyStream) -> Unit {
  self.terminate(None, false)
}

///|
pub fn BodyStream::fail(self : BodyStream, error : Error) -> Unit {
  self.terminate(Some(error), false)
}

///|
/// Cancels the stream, preserving the first terminal reason and immediately
/// releasing buffered frames and blocked producers.
pub fn BodyStream::cancel(self : BodyStream, error : Error) -> Unit {
  self.terminate(Some(error), true)
}

///|
pub impl Body for BodyStream with fn cancel(self, error) {
  self.cancel(error)
}

///|
async fn BodyStream::notify_data_consumed(
  self : BodyStream,
  amount : Int,
) -> Unit {
  errdefer self.cancel(BodyError::Cancelled)
  let outcome : Result[Unit, Error] = try {
    (self.on_data_consumed)(amount)
    Ok(())
  } catch {
    error => Err(error)
  }
  match outcome {
    Ok(_) => ()
    Err(error) => {
      self.cancel(error)
      raise error
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
    while true {
      errdefer self.cancel(BodyError::Cancelled)
      let outcome : Result[Frame?, Error] = Ok(pull()) catch {
        error => Err(error)
      }
      let output = match outcome {
        Ok(value) => value
        Err(error) => {
          self.cancel(error)
          raise error
        }
      }
      guard output is Some(frame) else {
        self.finish()
        return None
      }
      match validate_frame(frame, self.trailers_seen) {
        Err(error) => {
          self.cancel(error)
          raise error
        }
        Ok(SkipFrame) => continue
        Ok(DeliverFrame(trailers_seen)) => {
          self.trailers_seen = trailers_seen
          if frame is Data(data) {
            self.notify_data_consumed(data.length())
          } else {
            self.finish()
          }
          return Some(frame)
        }
      }
    }
  }
  let output = Some(self.queue.get()) catch {
    BodyStreamEnded => None
    error => raise error
  }
  if output is Some(Data(data)) {
    self.notify_data_consumed(data.length())
  }
  if output is Some(_) {
    ignore(self.space_available.try_put(()) catch { _ => false })
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
  if max_bytes < 0 {
    let error = BodyError::InvalidLimit(max_bytes)
    body.cancel(error)
    raise error
  }
  let data : Array[Byte] = []
  let mut trailers : @types.HeaderMap? = None
  let mut trailers_seen = false
  errdefer body.cancel(BodyError::Cancelled)
  while true {
    let outcome : Result[Frame?, Error] = Ok(body.next_frame()) catch {
      error => Err(error)
    }
    let next = match outcome {
      Ok(value) => value
      Err(error) => {
        body.cancel(error)
        raise error
      }
    }
    guard next is Some(frame) else { break }
    match validate_frame(frame, trailers_seen) {
      Err(error) => {
        body.cancel(error)
        raise error
      }
      Ok(SkipFrame) => ()
      Ok(DeliverFrame(next_trailers_seen)) => {
        trailers_seen = next_trailers_seen
        match frame {
          Data(chunk) => {
            if chunk.length() > max_bytes - data.length() {
              let error = BodyLimitExceeded(limit=max_bytes)
              body.cancel(error)
              raise error
            }
            for byte in chunk {
              data.push(byte)
            }
          }
          Trailers(value) => trailers = Some(value)
        }
      }
    }
  }
  (Bytes::from_array(data), trailers)
}
