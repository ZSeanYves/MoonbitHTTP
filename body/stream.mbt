///|
priv suberror BodyStreamEnded derive(Debug)

///|
/// A bounded asynchronous body stream.
///
/// `push` suspends when the configured queue is full, providing backpressure
/// to the protocol reader. `finish` marks a normal end of stream, while
/// `fail` wakes all consumers with the original error.
pub struct BodyStream {
  priv queue : @aqueue.Queue[Frame]
  priv space_available : @aqueue.Queue[Unit]
  priv hint : SizeHint
  priv on_data_consumed : async (Int) -> Unit
  priv on_terminate : (Error?) -> Unit
  priv pull : (async () -> Frame?)?
  priv mut status : StreamStatus
  priv mut trailers_seen : Bool
}

///|
priv enum StreamStatus {
  Open
  Finished
  Failed(Error)
}

///|
fn BodyStream::is_finished(self : BodyStream) -> Bool {
  !(self.status is Open)
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
    status: Open,
    trailers_seen: false,
  }
}

///|
pub fn BodyStream::new(
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
    status: Open,
    trailers_seen: false,
  }
}

///|
fn BodyStream::terminal_error(self : BodyStream) -> Error {
  match self.status {
    Failed(error) => error
    Open | Finished => BodyStreamEnded
  }
}

///|
fn BodyStream::terminate(
  self : BodyStream,
  error : Error?,
  clear : Bool,
) -> Unit {
  if self.is_finished() {
    return
  }
  self.status = match error {
    Some(error) => Failed(error)
    None => Finished
  }
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
  if self.is_finished() {
    raise self.terminal_error()
  }
  errdefer self.cancel(BodyError::Cancelled)
  while true {
    if self.is_finished() {
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
  if self.is_finished() {
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
    if self.is_finished() {
      return match self.status {
        Failed(error) => raise error
        Open | Finished => None
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
