///|
/// One shutdown signal can stop admission on all connections owned by a listener.
pub struct ServerShutdown {
  priv changed : @cond_var.Cond
  priv mut started : Bool
}

///|
pub fn ServerShutdown::new() -> ServerShutdown {
  { changed: Cond(), started: false, }
}

///|
pub fn ServerShutdown::has_started(self : ServerShutdown) -> Bool {
  self.started
}

///|
pub fn ServerShutdown::begin(self : ServerShutdown) -> Unit {
  if !self.started {
    self.started = true
    self.changed.broadcast()
  }
}

///|
pub async fn ServerShutdown::wait(self : ServerShutdown) -> Unit noraise {
  while !self.started {
    self.changed.wait()
  }
}
