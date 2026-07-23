///|
async test "uv adapter: callback transport implements official IO traits" {
  let source = b"input"
  let mut source_offset = 0
  let written : Array[Byte] = []
  let transport = CallbackTransport::new(
    async fn(destination, offset, max_len) {
      @async.pause()
      let remaining = source.length() - source_offset
      let count = remaining.min(max_len)
      for i in 0..<count {
        destination[offset + i] = source[source_offset + i]
      }
      source_offset += count
      count
    },
    async fn(bytes, offset, len) {
      @async.pause()
      for i in offset..<(offset + len) {
        written.push(bytes[i])
      }
      len
    },
  )
  assert_eq(transport.read_some(), Some(b"input"))
  transport.write(b"output")
  assert_eq(Bytes::from_array(written), b"output")
}
