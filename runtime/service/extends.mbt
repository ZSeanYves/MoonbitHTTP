///|
pub extend ServiceConfigError with Eq::{equal, not_equal}

///|
pub extend ServiceConfigError with @debug.Debug::{to_repr}

///|
pub extend ClientConnectionPhase with Eq::{equal, not_equal}

///|
pub extend ClientConnectionPhase with @debug.Debug::{to_repr}

///|
pub extend ClientConnectionTimeout with Eq::{equal, not_equal}

///|
pub extend ClientConnectionTimeout with @debug.Debug::{to_repr}

///|
pub extend ClientConnectionError with Eq::{equal, not_equal}

///|
pub extend ClientConnectionError with @debug.Debug::{to_repr}

///|
pub extend StreamIo with @aio.BinaryReader::{
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
pub extend StreamIo with @aio.BinaryWriter::{
  write,
  write_reader,
  flush_partial_data,
}

///|
pub extend StreamIoError with @debug.Debug::{to_repr}

///|
pub extend H3ClientError with Eq::{equal, not_equal}

///|
pub extend H3ClientError with @debug.Debug::{to_repr}
