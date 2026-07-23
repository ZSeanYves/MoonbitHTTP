///|
test "http-test: HTTP/1 request parses at every single split boundary" {
  let input = b"POST /upload HTTP/1.1\r\nHost: example.test\r\nContent-Length: 4\r\n\r\ndata"
  for split in 1..<input.length() {
    let decoder = @http1.RequestDecoder::new()
    let mut saw_head = false
    let mut saw_end = false
    let body : Array[Byte] = []
    let accept = fn(event : @http1.RequestEvent) {
      match event {
        RequestHead(_) => saw_head = true
        RequestData(bytes) =>
          for byte in bytes {
            body.push(byte)
          }
        RequestTrailers(_) => ()
        RequestEnd => saw_end = true
      }
    }
    assert_eq(decoder.feed(input[:split]), Ok(()))
    while decoder.next() is Ok(Some(event)) {
      accept(event)
    }
    assert_eq(decoder.feed(input[split:]), Ok(()))
    while decoder.next() is Ok(Some(event)) {
      accept(event)
    }
    assert_eq(saw_head, true)
    assert_eq(saw_end, true)
    assert_eq(Bytes::from_array(body), b"data")
  }
}

///|
async test "http-test: fault reader raises at configured boundary" {
  let reader = FaultReader::new([b"a", b"b"], fail_after=Some(1))
  assert_eq(reader.read_some(), Some(b"a"))
  let raised = try {
    ignore(reader.read_some())
    false
  } catch {
    _ => true
  }
  assert_eq(raised, true)
}
