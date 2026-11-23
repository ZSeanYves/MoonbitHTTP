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
pub extend StreamIo with @aio.Reader::{
  read,
  read_some,
  _direct_read,
  drop,
  read_all,
  read_until,
  read_exactly,
  _get_internal_buffer,
}

///|
pub extend StreamIo with @aio.Writer::{write_once, write, write_reader}

///|
pub extend StreamIoError with @debug.Debug::{to_repr}
