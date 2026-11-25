///|
/// A readable, cancellable body. Consuming trailers or EOF completes its ownership scope.
pub struct IncomingBody {
  priv mut reading : Bool
  priv hint : @body.SizeHint
  priv mut state : IncomingState
}

///|
priv enum IncomingState {
  Readable(async () -> @body.Frame?, (Error) -> Unit, () -> Unit)
  Finished
  Failed(Error)
}

///|
fn IncomingBody::new(
  read : async () -> @body.Frame?,
  hint : @body.SizeHint,
  stop : (Error) -> Unit,
  done~ : () -> Unit = () => (),
) -> IncomingBody {
  { hint, reading: false, state: Readable(read, stop, done), }
}

///|
pub fn[B : @body.Body] IncomingBody::wrap(body : B) -> IncomingBody {
  IncomingBody::new(async fn() { body.next_frame() }, body.size_hint(), reason => {
    body.cancel(reason)
  })
}

///|
pub impl @body.Body for IncomingBody with fn size_hint(self) {
  self.hint
}

///|
pub impl @body.Body for IncomingBody with fn cancel(self, reason) {
  if self.state is Readable(_, stop, done) {
    self.state = Failed(reason)
    stop(reason)
    done()
  }
}

///|
pub impl @body.Body for IncomingBody with fn next_frame(self) {
  let (read, done) = match self.state {
    Failed(reason) => raise reason
    Finished => return None
    Readable(read, _, done) => (read, done)
  }
  guard !self.reading else {
    raise ClientProtocol("concurrent reads of one response body")
  }
  self.reading = true
  defer {
    self.reading = false
  }
  errdefer self.cancel(@body.BodyError::Cancelled)
  let frame = read() catch {
    reason => {
      let first = match self.state {
        Failed(saved) => saved
        _ => reason
      }
      self.cancel(first)
      raise first
    }
  }
  if self.state is Failed(reason) {
    raise reason
  }
  if frame is (None | Some(Trailers(_))) {
    self.state = Finished
    done()
  }
  frame
}

///|
pub extend IncomingBody with @body.Body::{next_frame, size_hint, cancel}

///|
fn saved_body(data : Bytes, trailers : @types.HeaderMap?) -> IncomingBody {
  let frames : Array[@body.Frame] = []
  if !data.is_empty() {
    frames.push(Data(data))
  }
  if trailers is Some(fields) {
    frames.push(Trailers(fields))
  }
  IncomingBody::wrap(@body.QueueBody::new(frames))
}
