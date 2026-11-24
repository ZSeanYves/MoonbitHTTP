///|
pub extend CallbackTransport with @aio.BinaryReader::{
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
pub extend CallbackTransport with @aio.BinaryWriter::{
  write,
  write_reader,
  flush_partial_data,
}

///|
pub extend CallbackTransportClosed with Eq::{equal, not_equal}

///|
pub extend CallbackTransportClosed with @debug.Debug::{to_repr}
