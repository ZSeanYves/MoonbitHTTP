///|
/// Adapts async callbacks from uv.mbt or another event loop to Reader/Writer.
/// The adapter does not pin a uv version or add native dependencies to codecs.
#warnings("-alert_internal")
pub struct CallbackTransport {
  reader_buffer : @aio.ReaderBuffer
  read_callback : async (FixedArray[Byte], Int, Int) -> Int
  write_callback : async (Bytes, Int, Int) -> Int
  close_callback : () -> Unit
  mut closed : Bool
}

///|
#warnings("-alert_internal")
pub fn CallbackTransport::new(
  read_callback : async (FixedArray[Byte], Int, Int) -> Int,
  write_callback : async (Bytes, Int, Int) -> Int,
  close_callback? : () -> Unit = fn() { () },
) -> CallbackTransport {
  {
    reader_buffer: @aio.ReaderBuffer::new(),
    read_callback,
    write_callback,
    close_callback,
    closed: false,
  }
}

///|
pub fn CallbackTransport::close(self : CallbackTransport) -> Unit {
  if !self.closed {
    self.closed = true
    (self.close_callback)()
  }
}

///|
#warnings("-alert_internal")
pub impl @aio.Reader for CallbackTransport with fn _get_internal_buffer(self) {
  self.reader_buffer
}

///|
pub impl @aio.Reader for CallbackTransport with fn _direct_read(
  self,
  destination,
  offset~,
  max_len~,
) {
  if self.closed {
    0
  } else {
    (self.read_callback)(destination, offset, max_len)
  }
}

///|
pub impl @aio.Writer for CallbackTransport with fn write_once(
  self,
  source,
  offset~,
  len~,
) {
  if self.closed {
    raise CallbackTransportClosed
  }
  (self.write_callback)(source, offset, len)
}

///|
pub(all) suberror CallbackTransportClosed {
  CallbackTransportClosed
} derive(Debug, Eq)
