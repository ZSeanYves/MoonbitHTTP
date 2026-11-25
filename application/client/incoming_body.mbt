///|
/// A readable, cancellable body. Consuming trailers or EOF completes its ownership scope.
pub struct IncomingBody {
  priv read : async () -> @body.Frame?
  priv hint : @body.SizeHint
  priv stop : (Error) -> Unit
  priv done : () -> Unit
  priv mut ended : Bool
  priv mut failure : Error?
}

///|
fn IncomingBody::new(
  read : async () -> @body.Frame?,
  hint : @body.SizeHint,
  stop : (Error) -> Unit,
  done~ : () -> Unit = () => (),
) -> IncomingBody {
  { read, hint, stop, done, ended: false, failure: None, }
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
  if !self.ended {
    self.ended = true
    self.failure = Some(reason)
    (self.stop)(reason)
    (self.done)()
  }
}

///|
pub impl @body.Body for IncomingBody with fn next_frame(self) {
  if self.failure is Some(reason) {
    raise reason
  }
  if self.ended {
    return None
  }
  errdefer self.cancel(@body.BodyError::Cancelled)
  let frame = (self.read)() catch {
    reason => {
      self.cancel(reason)
      raise self.failure.unwrap_or(reason)
    }
  }
  if self.failure is Some(reason) {
    raise reason
  }
  if frame is (None | Some(Trailers(_))) {
    self.ended = true
    (self.done)()
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
