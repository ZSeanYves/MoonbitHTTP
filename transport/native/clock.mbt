///|
/// Native clock with independent monotonic and wall-clock sources. Deadlines
/// use elapsed monotonic time; HTTP dates and cookie expiry use Unix time.
pub struct NativeClock {
  started : @bench.Timestamp
}

///|
pub fn NativeClock::new() -> NativeClock {
  { started: @bench.monotonic_clock_start(), }
}

///|
pub impl @transport.Clock for NativeClock with fn monotonic_millis(self) {
  (@bench.monotonic_clock_end(self.started) / 1000.0).to_int64()
}

///|
pub impl @transport.Clock for NativeClock with fn wall_clock_seconds(_self) {
  @env.now().reinterpret_as_int64() / 1000L
}
