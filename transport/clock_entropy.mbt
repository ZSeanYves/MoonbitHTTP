///|
pub(open) trait Clock {
  fn monotonic_millis(Self) -> Int64
  fn wall_clock_seconds(Self) -> Int64
}

///|
pub(open) trait Entropy {
  fn fill(Self, FixedArray[Byte]) -> Result[Unit, EntropyError]
}
