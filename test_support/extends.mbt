///|
pub extend InjectedIoError with Eq::{equal, not_equal}

///|
pub extend InjectedIoError with @debug.Debug::{to_repr}

///|
pub extend FaultReader with @aio.Reader::{
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
pub extend RecordingWriter with @aio.Writer::{write_once, write, write_reader}
