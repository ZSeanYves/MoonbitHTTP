///|
struct CaptureWriter {
  bytes : Array[Byte]
}

///|
impl @aio.Writer for CaptureWriter with fn write_once(self, data, offset~, len~) {
  for i in offset..<(offset + len) {
    self.bytes.push(data[i])
  }
  len
}

///|
async test "service: HTTP/1 runs on official async Reader/Writer" {
  let reader = @aio.MemoryReader(async fn(writer) {
    writer.write(
      b"GET / HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n",
    )
  })
  let writer : CaptureWriter = { bytes: [] }
  serve_http1_connection(reader, writer, async fn(request) {
    @async.pause()
    assert_eq(request.uri.value, "/")
    let headers = @types.HeaderMap::new()
    assert_eq(headers.append_string("content-type", "text/plain"), Ok(()))
    { status: 200, version: Http11, headers, body: b"hello" }
  })
  assert_eq(
    Bytes::from_array(writer.bytes).find(b"HTTP/1.1 200 OK") is Some(_),
    true,
  )
  assert_eq(Bytes::from_array(writer.bytes).has_suffix(b"hello"), true)
}

///|
async test "service: client handshake sends request and streams response" {
  let reader = @aio.MemoryReader(async fn(writer) {
    writer.write(
      b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\nX-End: yes\r\n\r\n",
    )
  })
  let writer : CaptureWriter = { bytes: [] }
  let client = ClientConnection::new(reader, writer)
  let headers = @types.HeaderMap::new()
  assert_eq(headers.append_string("host", "example.test"), Ok(()))
  let request : @types.Request[Bytes] = {
    http_method: Get,
    uri: @types.Uri::parse("/").unwrap(),
    version: Http11,
    headers,
    body: b"",
  }
  let result = client.send(request)
  assert_eq(result.response.status, 200)
  assert_eq(result.response.body, b"ok")
  assert_eq(
    result.trailers.unwrap().get_string("x-end").unwrap().to_string_lossy(),
    "yes",
  )
  assert_eq(
    Bytes::from_array(writer.bytes).has_prefix(b"GET / HTTP/1.1\r\n"),
    true,
  )
}
