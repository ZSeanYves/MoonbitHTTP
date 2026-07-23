///|
test "http1 conformance: content-length is strict decimal" {
  for value in ["+1", "1x", "2147483648"] {
    let decoder = RequestDecoder::new()
    decoder
    .feed(
      @utf8.encode(
        "POST / HTTP/1.1\r\nHost: example.test\r\nContent-Length: " +
        value +
        "\r\n\r\n",
      ),
    )
    .unwrap()
    assert_eq(decoder.next() is Err(InvalidFraming(_)), true)
  }
}

///|
test "http1 conformance: duplicate content-length accepts only identical values" {
  let accepted = RequestDecoder::new()
  accepted
  .feed(
    b"POST / HTTP/1.1\r\nHost: example.test\r\nContent-Length: 04\r\nContent-Length: 4\r\n\r\nbody",
  )
  .unwrap()
  assert_eq(accepted.next() is Ok(Some(RequestHead(_))), true)
  assert_eq(accepted.next() is Ok(Some(RequestData(b"body"))), true)
  assert_eq(accepted.next() is Ok(Some(RequestEnd)), true)

  let rejected = RequestDecoder::new()
  rejected
  .feed(
    b"POST / HTTP/1.1\r\nHost: example.test\r\nContent-Length: 4\r\nContent-Length: 5\r\n\r\nbody",
  )
  .unwrap()
  assert_eq(rejected.next() is Err(InvalidFraming(_)), true)
}

///|
test "http1 conformance: unsupported transfer coding cannot define a request body" {
  let decoder = RequestDecoder::new()
  decoder
  .feed(
    b"POST / HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: gzip\r\n\r\n",
  )
  .unwrap()
  assert_eq(decoder.next() is Err(InvalidFraming(_)), true)
}

///|
test "http1 conformance: malformed status code is rejected" {
  let decoder = ResponseDecoder::new(Get)
  decoder.feed(b"HTTP/1.1 +00 Bad\r\n\r\n").unwrap()
  assert_eq(decoder.next() is Err(InvalidStartLine(_)), true)
}
