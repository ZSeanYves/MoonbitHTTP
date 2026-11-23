///|
#derive(Debug)
pub(all) suberror StreamIoError {
  StreamIoError(@transport.TransportError)
}

///|
#warnings("-alert_internal")
pub struct StreamIo {
  priv reader_buffer : @aio.ReaderBuffer
  priv connection : @transport.StreamConnection
}

///|
#warnings("-alert_internal")
pub fn StreamIo::new(connection : @transport.StreamConnection) -> StreamIo {
  { reader_buffer: @aio.ReaderBuffer::new(), connection, }
}

///|
#warnings("-alert_internal")
pub impl @aio.Reader for StreamIo with fn _get_internal_buffer(self) {
  self.reader_buffer
}

///|
#warnings("-alert_internal")
pub impl @aio.Reader for StreamIo with fn _direct_read(
  self,
  destination,
  offset~,
  max_len~,
) {
  match self.connection.read(max_len) {
    Err(error) => raise StreamIoError(error)
    Ok(None) => 0
    Ok(Some(bytes)) => {
      if bytes.is_empty() {
        raise StreamIoError(
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
#warnings("-alert_internal")
pub impl @aio.Writer for StreamIo with fn write_once(
  self,
  source,
  offset~,
  len~,
) {
  let bytes = source[offset:offset + len].to_owned()
  match self.connection.write(bytes) {
    Ok(_) => len
    Err(error) => raise StreamIoError(error)
  }
}
