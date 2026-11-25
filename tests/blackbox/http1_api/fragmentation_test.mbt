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
test "body decoders inherit EOF signalled before reading the head" {
  let close = @http1.ResponseDecoder::new(Get)
  close.feed(b"HTTP/1.0 200 OK\r\n\r\nhello").unwrap()
  close.finish_input()
  assert_true(close.next() is Ok(Some(ResponseHead(_))))
  assert_true(close.next() is Ok(Some(ResponseData(b"hello"))))
  assert_true(close.next() is Ok(Some(ResponseEnd)))
  assert_true(close.next() is Ok(None))

  let fixed = @http1.ResponseDecoder::new(Get)
  fixed.feed(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\na").unwrap()
  fixed.finish_input()
  assert_true(fixed.next() is Ok(Some(ResponseHead(_))))
  assert_true(fixed.next() is Ok(Some(ResponseData(b"a"))))
  assert_true(fixed.next() is Err(UnexpectedEof(_)))

  let request = @http1.RequestDecoder::new()
  request
  .feed(b"POST / HTTP/1.1\r\nHost: origin.test\r\nContent-Length: 2\r\n\r\na")
  .unwrap()
  request.finish_input()
  assert_true(request.next() is Ok(Some(RequestHead(_))))
  assert_true(request.next() is Ok(Some(RequestData(b"a"))))
  assert_true(request.next() is Err(UnexpectedEof(_)))
}
