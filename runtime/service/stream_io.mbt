///|
#derive(Debug)
pub(all) suberror StreamIoError {
  StreamIoError(@transport.TransportError)
}

///|
pub struct StreamIo {
  priv writer_controller : @aio.BinaryWriterController
  priv reader_controller : @aio.BinaryReaderController
  priv connection : @transport.StreamConnection
}

///|
pub fn StreamIo::new(connection : @transport.StreamConnection) -> StreamIo {
  {
    writer_controller: BinaryWriterController(),
    reader_controller: BinaryReaderController(),
    connection,
  }
}

///|
pub impl @aio.BinaryReader for StreamIo

///|
impl @aio.BinaryReaderImpl for StreamIo with fn name(_self) {
  "StreamIo"
}

///|
impl @aio.BinaryReaderImpl for StreamIo with fn get_controller(self) {
  self.reader_controller
}

///|
impl @aio.BinaryReaderImpl for StreamIo with fn raw_read_impl(
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
      destination.blit_from_bytes(offset, bytes, 0, bytes.length())
      bytes.length()
    }
  }
}

///|
pub impl @aio.BinaryWriter for StreamIo

///|
impl @aio.BinaryWriterImpl for StreamIo with fn name(_self) {
  "StreamIo"
}

///|
impl @aio.BinaryWriterImpl for StreamIo with fn get_controller(self) {
  self.writer_controller
}

///|
impl @aio.BinaryWriterImpl for StreamIo with fn flush_partial_data(_self) {
  ()
}

///|
impl @aio.BinaryWriterImpl for StreamIo with fn raw_write_impl(
  self,
  source,
  offset~,
  len~,
) {
  let bytes = if offset == 0 && len == source.length() {
    source
  } else {
    source[offset:offset + len].to_owned()
  }
  match self.connection.write(bytes) {
    Ok(_) => len
    Err(error) => raise StreamIoError(error)
  }
}
