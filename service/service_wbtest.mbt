///|
struct TimeoutCaptureWriter {
  bytes : Array[Byte]
}

///|
impl @aio.Writer for TimeoutCaptureWriter with fn write_once(
  self,
  data,
  offset~,
  len~,
) {
  for i in offset..<(offset + len) {
    self.bytes.push(data[i])
  }
  len
}

///|
async test "service timeout helpers preserve bytes and default policy" {
  let defaults = ServerConfig::defaults()
  assert_eq(defaults.read_timeout_ms, None)
  assert_eq(defaults.write_timeout_ms, None)
  let reader = @aio.MemoryReader(async fn(writer) { writer.write(b"ok") })
  assert_eq(read_some_with_timeout(reader, 16, Some(100)), Some(b"ok"))
  let writer : TimeoutCaptureWriter = { bytes: [] }
  write_with_timeout(writer, b"ok", Some(100))
  assert_eq(Bytes::from_array(writer.bytes), b"ok")
}
