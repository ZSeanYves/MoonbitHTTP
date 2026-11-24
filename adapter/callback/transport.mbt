///|
/// Adapts host callbacks to the async binary reader and writer interfaces.
pub struct CallbackTransport {
  priv writer_controller : @aio.BinaryWriterController
  priv reader_controller : @aio.BinaryReaderController
  priv read_callback : async (FixedArray[Byte], Int32, Int32) -> Int32
  priv write_callback : async (Bytes, Int32, Int32) -> Int32
  priv close_callback : () -> Unit
  priv mut closed : Bool
}

///|
pub fn CallbackTransport::new(
  read_callback : async (FixedArray[Byte], Int32, Int32) -> Int32,
  write_callback : async (Bytes, Int32, Int32) -> Int32,
  close_callback~ : () -> Unit = fn() { () },
) -> CallbackTransport {
  {
    writer_controller: BinaryWriterController(),
    reader_controller: BinaryReaderController(),
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
pub impl @aio.BinaryReader for CallbackTransport

///|
impl @aio.BinaryReaderImpl for CallbackTransport with fn name(_self) {
  "CallbackTransport"
}

///|
impl @aio.BinaryReaderImpl for CallbackTransport with fn get_controller(self) {
  self.reader_controller
}

///|
impl @aio.BinaryReaderImpl for CallbackTransport with fn raw_read_impl(
  self,
  destination,
  offset~,
  max_len~,
) {
  if self.closed {
    0
  } else {
    let count = (self.read_callback)(destination, offset, max_len)
    guard count >= 0 && count <= max_len else {
      raise InvalidReadCount(count, limit=max_len)
    }
    count
  }
}

///|
pub impl @aio.BinaryWriter for CallbackTransport

///|
impl @aio.BinaryWriterImpl for CallbackTransport with fn name(_self) {
  "CallbackTransport"
}

///|
impl @aio.BinaryWriterImpl for CallbackTransport with fn get_controller(self) {
  self.writer_controller
}

///|
impl @aio.BinaryWriterImpl for CallbackTransport with fn flush_partial_data(
  _self,
) {
  ()
}

///|
impl @aio.BinaryWriterImpl for CallbackTransport with fn raw_write_impl(
  self,
  source,
  offset~,
  len~,
) {
  if self.closed {
    raise CallbackTransportClosed
  }
  let count = (self.write_callback)(source, offset, len)
  guard count > 0 && count <= len else {
    raise InvalidWriteCount(count, limit=len)
  }
  count
}

///|
#derive(Debug, Eq)
pub(all) suberror CallbackTransportClosed {
  CallbackTransportClosed
}

///|
/// A host callback reported progress outside the supplied buffer range.
pub(all) suberror CallbackCountError {
  InvalidReadCount(Int32, limit~ : Int32)
  InvalidWriteCount(Int32, limit~ : Int32)
}
