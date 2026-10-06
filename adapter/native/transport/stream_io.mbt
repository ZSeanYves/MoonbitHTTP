///|
/// A Native-only bridge from MoonbitHTTP's transport contract to async's
/// Reader/Writer traits.
///
/// The bridge deliberately keeps StreamConnection as the owner of endpoint,
/// cancellation, timeout, and close semantics. It only translates the byte
/// buffer shape and preserves transport failures as a raised error.
#warnings("-alert_internal")
pub struct NativeStreamIo {
  reader_buffer : @aio.ReaderBuffer
  connection : @transport_api.StreamConnection
}

///|
#warnings("-alert_internal")
pub fn NativeStreamIo::new(
  connection : @transport_api.StreamConnection,
) -> NativeStreamIo {
  { reader_buffer: @aio.ReaderBuffer::new(), connection, }
}

///|
pub fn NativeStreamIo::close(self : NativeStreamIo) -> Unit {
  self.connection.close()
}

///|
pub impl @aio.Reader for NativeStreamIo with fn _get_internal_buffer(self) {
  self.reader_buffer
}

///|
pub impl @aio.Reader for NativeStreamIo with fn _direct_read(
  self,
  destination,
  offset~,
  max_len~,
) {
  match self.connection.read(max_len) {
    Err(error) => raise NativeStreamIoError(error)
    Ok(None) => 0
    Ok(Some(bytes)) => {
      if bytes.is_empty() {
        raise NativeStreamIoError(
          Failed(Receive, "stream returned an empty non-EOF read"),
        )
      }
      for index in 0..<bytes.length() {
        destination[offset + index] = bytes[index]
      }
      bytes.length()
    }
  }
}

///|
pub impl @aio.Writer for NativeStreamIo with fn write_once(
  self,
  source,
  offset~,
  len~,
) {
  let bytes = source[offset:offset + len].to_owned()
  match self.connection.write(bytes) {
    Ok(_) => len
    Err(error) => raise NativeStreamIoError(error)
  }
}

///|
/// Transport failures raised while implementing async's Reader/Writer traits.
pub(all) suberror NativeStreamIoError {
  NativeStreamIoError(@transport_api.TransportError)
} derive(Debug, Eq)

///|
pub extend NativeStreamIo with @aio.Reader::{
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
pub extend NativeStreamIo with @aio.Writer::{write_once, write, write_reader}

///|
pub extend NativeStreamIoError with @debug.Debug::{to_repr}

///|
pub extend NativeStreamIoError with Eq::{not_equal, equal}
