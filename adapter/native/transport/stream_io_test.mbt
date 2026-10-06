///|
async test "native stream io adapts bytes and EOF" {
  let endpoint = @types.Endpoint::new("tcp", "127.0.0.1", 80).unwrap()
  let input = b"input"
  let output : Array[Byte] = []
  let mut offset = 0
  let connection = @transport_api.StreamConnection::new(
    endpoint,
    fn(max_len) {
      let remaining = input.length() - offset
      if remaining == 0 {
        Ok(None)
      } else {
        let count = remaining.min(max_len)
        let chunk = input[offset:offset + count].to_owned()
        offset += count
        Ok(Some(chunk))
      }
    },
    fn(bytes) {
      for byte in bytes {
        output.push(byte)
      }
      Ok(())
    },
    fn() { () },
  )
  let io = @transport.NativeStreamIo::new(connection)
  assert_eq(io.read_some(), Some(b"input"))
  assert_eq(io.read_some(), None)
  io.write(b"output")
  assert_eq(Bytes::from_array(output), b"output")
}

///|
async test "native stream io rejects empty non-EOF reads" {
  let endpoint = @types.Endpoint::new("tcp", "127.0.0.1", 80).unwrap()
  let connection = @transport_api.StreamConnection::new(
    endpoint,
    fn(_) { Ok(Some(b"")) },
    fn(_) { Ok(()) },
    fn() { () },
  )
  let io = @transport.NativeStreamIo::new(connection)
  let raised = try {
    ignore(io.read_some())
    false
  } catch {
    _ => true
  }
  assert_true(raised)
}
