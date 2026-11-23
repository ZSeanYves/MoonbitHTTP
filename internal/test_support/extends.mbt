///|
pub extend InjectedIoError with Eq::{equal, not_equal}

///|
pub extend InjectedIoError with @debug.Debug::{to_repr}

///|
pub extend FaultReader with @aio.BinaryReader::{
  read,
  read_into,
  read_all,
  read_until,
  read_exactly,
  drop_exactly,
  peek,
  peek_at_least,
  peek_exactly,
  peek_until,
  read_at_least,
  drop_all,
}

///|
pub extend RecordingWriter with @aio.BinaryWriter::{
  write,
  write_reader,
  flush_partial_data,
}

///|
pub extend FixedClock with Eq::{equal, not_equal}

///|
pub extend FixedClock with @debug.Debug::{to_repr}

///|
pub extend FixedClock with @transport.Clock::{
  monotonic_millis,
  wall_clock_seconds,
}

///|
pub extend ZeroEntropy with @transport.Entropy::{fill}

///|
pub extend MemoryDatagramSocket with @transport.DatagramSocket::{
  send,
  receive,
  close,
}
