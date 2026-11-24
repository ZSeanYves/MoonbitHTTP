///|
/// Adapt test-specific write behavior to the same binary I/O callback adapter as callers.
trait TestWriter {
  async fn write_once(Self, Bytes, offset~ : Int32, len~ : Int32) -> Int32
}

///|
fn[W : TestWriter] test_writer(writer : W) -> @callback.CallbackTransport {
  @callback.CallbackTransport::new(fn(_, _, _) { 0 }, async fn(
    bytes,
    offset,
    len,
  ) {
    writer.write_once(bytes, offset~, len~)
  })
}
