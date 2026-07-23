///|
test "bench HTTP/1 incremental request decode" (it : @bench.T) {
  let input = b"POST /upload HTTP/1.1\r\nHost: example.test\r\nContent-Length: 1024\r\n\r\n" +
    Bytes::make(1024, b'a')
  it.bench(fn() {
    let decoder = RequestDecoder::new()
    ignore(decoder.feed(input))
    let mut events = 0
    while decoder.next() is Ok(Some(_)) {
      events += 1
    }
    it.keep(events)
  })
}
