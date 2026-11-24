///|
pub extend ServiceConfigError with Eq::{equal, not_equal}

///|
pub extend ServiceConfigError with @debug.Debug::{to_repr}

///|
pub extend Http1ClientPhase with Eq::{equal, not_equal}

///|
pub extend Http1ClientPhase with @debug.Debug::{to_repr}

///|
pub extend Http1ClientTimeout with Eq::{equal, not_equal}

///|
pub extend Http1ClientTimeout with @debug.Debug::{to_repr}

///|
pub extend Http1ClientError with Eq::{equal, not_equal}

///|
pub extend Http1ClientError with @debug.Debug::{to_repr}

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
pub extend Http3ClientError with Eq::{equal, not_equal}

///|
pub extend Http3ClientError with @debug.Debug::{to_repr}
