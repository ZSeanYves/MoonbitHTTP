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
struct SignalingCaptureWriter {
  bytes : Array[Byte]
  signal : @aqueue.Queue[Unit]
}

///|
impl @aio.Writer for SignalingCaptureWriter with fn write_once(
  self,
  data,
  offset~,
  len~,
) {
  for i in offset..<(offset + len) {
    self.bytes.push(data[i])
  }
  ignore(self.signal.try_put(()) catch { _ => false })
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
    {
      status: 200,
      version: Http11,
      headers,
      body: @body.FullBody::new(b"hello"),
    }
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
  let request : @types.Request[@body.FullBody] = {
    http_method: Get,
    uri: @types.Uri::parse("/").unwrap(),
    version: Http11,
    headers,
    body: @body.FullBody::new(b""),
  }
  let result = client.send(request)
  assert_eq(result.status, 200)
  let (response_body, trailers) = @body.collect(result.body)
  assert_eq(response_body, b"ok")
  assert_eq(
    trailers.unwrap().get_string("x-end").unwrap().to_string_lossy(),
    "yes",
  )
  assert_eq(
    Bytes::from_array(writer.bytes).has_prefix(b"GET / HTTP/1.1\r\n"),
    true,
  )
}

///|
async test "service: HTTP/1 streams request frames and response trailers" {
  let reader = @aio.MemoryReader(async fn(writer) {
    writer.write(
      b"POST /stream HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n2\r\nab\r\n2\r\ncd\r\n0\r\nX-In: yes\r\n\r\n",
    )
  })
  let writer : CaptureWriter = { bytes: [] }
  serve_http1_connection(reader, writer, async fn(request) {
    let (data, trailers) = @body.collect(request.body)
    assert_eq(data, b"abcd")
    assert_eq(
      trailers.unwrap().get_string("x-in").unwrap().to_string_lossy(),
      "yes",
    )
    let output_trailers = @types.HeaderMap::new()
    assert_eq(output_trailers.append_string("x-out", "yes"), Ok(()))
    {
      status: 200,
      version: Http11,
      headers: @types.HeaderMap::new(),
      body: @body.QueueBody::new([Data(b"ok"), Trailers(output_trailers)]),
    }
  })
  let output = Bytes::from_array(writer.bytes)
  assert_eq(output.find(b"transfer-encoding: chunked") is Some(_), true)
  assert_eq(output.find(b"2\r\nok\r\n") is Some(_), true)
  assert_eq(output.find(b"x-out: yes\r\n") is Some(_), true)
}

///|
async test "service: HTTP/2 client sends preface and receives streamed body" {
  let response : @types.Response[Bytes] = {
    status: 200,
    version: Http2,
    headers: @types.HeaderMap::new(),
    body: b"h2-ok",
  }
  let input : Array[Byte] = []
  for byte in @http2.encode_settings_frame([], false) {
    input.push(byte)
  }
  for
    byte in @http2.encode_response_frames(
      @http2.HpackContext::new(),
      1,
      response,
    ).unwrap() {
    input.push(byte)
  }
  let request_written : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
  let reader = @aio.MemoryReader(async fn(writer) {
    for _ in 0..<4 {
      request_written.get()
    }
    writer.write(Bytes::from_array(input))
  })
  let writer : SignalingCaptureWriter = { bytes: [], signal: request_written }
  with_h2_client_connection(reader, writer, async fn(client) {
    let headers = @types.HeaderMap::new()
    assert_eq(headers.append_string("host", "example.test"), Ok(()))
    let request : @types.Request[@body.FullBody] = {
      http_method: Get,
      uri: @types.Uri::parse("/h2").unwrap(),
      version: Http2,
      headers,
      body: @body.FullBody::new(b""),
    }
    let result = client.send(request)
    let first = result.body.next_frame()
    guard first is Some(Data(data)) else { fail("missing H2 response DATA") }
    let end = result.body.next_frame()
    assert_eq(end is None, true)
    assert_eq(result.status, 200)
    assert_eq(data, b"h2-ok")
  })
  let output = Bytes::from_array(writer.bytes)
  assert_eq(output.has_prefix(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"), true)
}

///|
async test "service: HTTP/2 client multiplexes two response streams" {
  let input : Array[Byte] = []
  for byte in @http2.encode_settings_frame([], false) {
    input.push(byte)
  }
  let encoder = @http2.HpackContext::new()
  let stream_ids = [1, 3]
  let payloads = [b"one", b"two"]
  for index in 0..<stream_ids.length() {
    let response : @types.Response[Bytes] = {
      status: 200,
      version: Http2,
      headers: @types.HeaderMap::new(),
      body: payloads[index],
    }
    for
      byte in @http2.encode_response_frames(
        encoder,
        stream_ids[index],
        response,
      ).unwrap() {
      input.push(byte)
    }
  }
  let request_written : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
  let reader = @aio.MemoryReader(async fn(writer) {
    for _ in 0..<5 {
      request_written.get()
    }
    writer.write(Bytes::from_array(input))
  })
  let writer : SignalingCaptureWriter = { bytes: [], signal: request_written }
  with_h2_client_connection(reader, writer, async fn(client) {
    let results : @aqueue.Queue[Bytes] = Queue(kind=Unbounded)
    @async.with_task_group(async fn(group) {
      for path in ["/one", "/two"] {
        group.spawn_bg(async fn() {
          let headers = @types.HeaderMap::new()
          assert_eq(headers.append_string("host", "example.test"), Ok(()))
          let request : @types.Request[@body.EmptyBody] = {
            http_method: Get,
            uri: @types.Uri::parse(path).unwrap(),
            version: Http2,
            headers,
            body: @body.EmptyBody::new(),
          }
          let response = client.send(request)
          let (data, _) = @body.collect(response.body)
          results.put(data)
        })
      }
      let first = results.get()
      let second = results.get()
      assert_eq(
        (first == b"one" && second == b"two") ||
        (first == b"two" && second == b"one"),
        true,
      )
    })
  })
}

///|
async test "service: h2c upgrade streams request body into stream one" {
  let input : Array[Byte] = []
  for
    byte in b"POST /upgrade HTTP/1.1\r\nHost: example.test\r\nConnection: Upgrade, HTTP2-Settings\r\nUpgrade: h2c\r\nHTTP2-Settings: AAQAAP__\r\nContent-Length: 4\r\n\r\nabcd" {
    input.push(byte)
  }
  for byte in b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" {
    input.push(byte)
  }
  for byte in @http2.encode_settings_frame([], false) {
    input.push(byte)
  }
  let reader = @aio.MemoryReader(async fn(writer) {
    writer.write(Bytes::from_array(input))
  })
  let writer : CaptureWriter = { bytes: [] }
  let mut request_body = b""
  serve_http1_or_h2c_connection(reader, writer, async fn(request) {
    let (data, _) = @body.collect(request.body)
    request_body = data
    assert_eq(request.version, Http2)
    assert_eq(request.headers.get_all_string("upgrade").is_empty(), true)
    {
      status: 200,
      version: Http2,
      headers: @types.HeaderMap::new(),
      body: @body.FullBody::new(b"upgraded"),
    }
  })
  assert_eq(request_body, b"abcd")
  assert_eq(
    Bytes::from_array(writer.bytes).has_prefix(
      b"HTTP/1.1 101 Switching Protocols\r\n",
    ),
    true,
  )
}
