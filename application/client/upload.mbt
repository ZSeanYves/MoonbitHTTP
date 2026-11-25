///|
/// The source for one logical request. A factory produces a fresh body for each attempt.
pub struct Upload {
  priv source : UploadSource
}

///|
priv enum UploadSource {
  Buffered(Bytes)
  Once(Ref[IncomingBody?])
  Reopen(async () -> IncomingBody)
}

///|
pub fn Upload::bytes(data : Bytes) -> Upload {
  { source: Buffered(data), }
}

///|
pub fn[B : @body.Body] Upload::once(body : B) -> Upload {
  { source: Once(Ref(Some(IncomingBody::wrap(body)))), }
}

///|
pub fn[B : @body.Body] Upload::reopen(open : async () -> B) -> Upload {
  { source: Reopen(async fn() { IncomingBody::wrap(open()) }), }
}

///|
fn Upload::replayability(self : Upload) -> BodyReplayability {
  match self.source {
    Once(_) => NonReplayableBody
    _ => ReplayableBody
  }
}

///|
fn Upload::discard_unopened(self : Upload) -> Unit {
  if self.source is Once(slot) && slot.val is Some(body) {
    slot.val = None
    body.cancel(@body.BodyError::Cancelled)
  }
}

///|
async fn Upload::open(self : Upload) -> IncomingBody {
  match self.source {
    Buffered(data) => IncomingBody::wrap(@body.FullBody::new(data))
    Once(slot) => {
      guard slot.val is Some(body) else {
        raise ClientRetry(RetryBodyNotReplayable)
      }
      slot.val = None
      body
    }
    Reopen(factory) => factory()
  }
}
