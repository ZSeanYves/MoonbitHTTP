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
/// The default cancellation hook is a no-op for bodies that do not own
/// asynchronous resources. Resource-owning bodies
/// should override it so consumers such as `collect` can stop upstream work.
impl Body with fn cancel(_self, _error) {
  ()
}

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
