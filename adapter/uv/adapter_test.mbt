///|
async test "uv adapter: callback transport implements official IO traits" {
  let source = b"input"
  let mut source_offset = 0
  let written : Array[Byte] = []
  let transport = @uv.CallbackTransport::new(
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
      let count = len.min(2)
      for i in offset..<(offset + count) {
        written.push(bytes[i])
      }
      count
    },
  )
  assert_eq(transport.read(), Some(b"input"))
  transport.write(b"output")
  assert_eq(Bytes::from_array(written), b"output")
}

///|
async test "callback progress stays within the supplied slice" {
  for count in [-1, 4] {
    let stream = @uv.CallbackTransport::new(fn(_, _, _) { count }, fn(_, _, _) {
      1
    })
    let buffer = FixedArray::make(3, b'\x00')
    try ignore(stream.read_into(buffer.mut_view())) catch {
      TransportError(@uv.InvalidReadCount(actual, limit=3), ..) =>
        assert_eq(actual, count)
      error => raise error
    } noraise {
      _ => fail("invalid read count accepted")
    }
  }
  for count in [-1, 0, 4] {
    let stream = @uv.CallbackTransport::new(fn(_, _, _) { 0 }, fn(_, _, _) {
      count
    })
    try stream.write(b"abc") catch {
      TransportError(@uv.InvalidWriteCount(actual, limit=3), ..) =>
        assert_eq(actual, count)
      error => raise error
    } noraise {
      _ => fail("invalid write count accepted")
    }
  }
}
