///|
async test "service: HTTP/2 dispatches two streams on one connection" {
  let encoder = @http2.HpackContext::new()
  let headers = @types.HeaderMap::new()
  assert_eq(headers.append_string("host", "example.test"), Ok(()))
  let request_one : @types.Request[Bytes] = {
    http_method: Get,
    uri: @types.Uri::parse("/one").unwrap(),
    version: Http2,
    headers,
    body: b"",
  }
  let headers_two = @types.HeaderMap::new()
  assert_eq(headers_two.append_string("host", "example.test"), Ok(()))
  let request_two : @types.Request[Bytes] = {
    http_method: Get,
    uri: @types.Uri::parse("/two").unwrap(),
    version: Http2,
    headers: headers_two,
    body: b"",
  }
  let input : Array[Byte] = []
  for byte in b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" {
    input.push(byte)
  }
  for byte in @http2.encode_settings_frame([], false) {
    input.push(byte)
  }
  for byte in @http2.encode_request_frames(encoder, 1, request_one).unwrap() {
    input.push(byte)
  }
  for byte in @http2.encode_request_frames(encoder, 3, request_two).unwrap() {
    input.push(byte)
  }
  let reader = @aio.MemoryReader(async fn(writer) {
    writer.write(Bytes::from_array(input))
  })
  let writer = CaptureWriter::{ bytes: [] }
  let mut calls = 0
  serve_http2_connection(reader, writer, async fn(request) {
    calls += 1
    @async.pause()
    let response_headers = @types.HeaderMap::new()
    {
      status: 200,
      version: Http2,
      headers: response_headers,
      body: if request.uri.value == "/one" {
        b"one"
      } else {
        b"two"
      },
    }
  })
  assert_eq(calls, 2)
  let decoder = @http2.FrameDecoder::new(max_buffer_size=256 * 1024)
  assert_eq(decoder.feed(Bytes::from_array(writer.bytes)), Ok(()))
  let mut stream_one = false
  let mut stream_three = false
  while decoder.next() is Ok(Some(frame)) {
    if frame.header.typ == @http2.H2_FRAME_HEADERS &&
      frame.header.stream_id == 1 {
      stream_one = true
    }
    if frame.header.typ == @http2.H2_FRAME_HEADERS &&
      frame.header.stream_id == 3 {
      stream_three = true
    }
  }
  assert_eq(stream_one, true)
  assert_eq(stream_three, true)
}

///|
async test "service: HTTP/2 response honors flow-control windows" {
  let encoder = @http2.HpackContext::new()
  let headers = @types.HeaderMap::new()
  assert_eq(headers.append_string("host", "example.test"), Ok(()))
  let request : @types.Request[Bytes] = {
    http_method: Get,
    uri: @types.Uri::parse("/large").unwrap(),
    version: Http2,
    headers,
    body: b"",
  }
  let input : Array[Byte] = []
  for byte in b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" {
    input.push(byte)
  }
  for byte in @http2.encode_settings_frame([], false) {
    input.push(byte)
  }
  for byte in @http2.encode_request_frames(encoder, 1, request).unwrap() {
    input.push(byte)
  }
  for byte in @http2.encode_window_update(0, 65535).unwrap() {
    input.push(byte)
  }
  for byte in @http2.encode_window_update(1, 65535).unwrap() {
    input.push(byte)
  }
  let reader = @aio.MemoryReader(async fn(writer) {
    writer.write(Bytes::from_array(input))
  })
  let writer : CaptureWriter = { bytes: [] }
  serve_http2_connection(reader, writer, fn(_) {
    let body : Array[Byte] = []
    body.resize(70000, b'x')
    {
      status: 200,
      version: Http2,
      headers: @types.HeaderMap::new(),
      body: Bytes::from_array(body),
    }
  })
  let decoder = @http2.FrameDecoder::new(max_buffer_size=512 * 1024)
  decoder.feed(Bytes::from_array(writer.bytes)).unwrap()
  let mut total = 0
  let mut saw_end = false
  while decoder.next() is Ok(Some(frame)) {
    if frame.header.typ == @http2.H2_FRAME_DATA {
      total += frame.payload.length()
      saw_end = saw_end ||
        (frame.header.flags & @http2.H2_FLAGS_END_STREAM) != 0
    }
  }
  assert_eq(total, 70000)
  assert_eq(saw_end, true)
}

///|
async test "service: stream errors reset only the offending stream" {
  let encoder = @http2.HpackContext::new()
  let headers = @types.HeaderMap::new()
  assert_eq(headers.append_string("host", "example.test"), Ok(()))
  let request : @types.Request[Bytes] = {
    http_method: Get,
    uri: @types.Uri::parse("/valid").unwrap(),
    version: Http2,
    headers,
    body: b"",
  }
  let input : Array[Byte] = []
  for byte in b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" {
    input.push(byte)
  }
  for byte in @http2.encode_settings_frame([], false) {
    input.push(byte)
  }
  input.push(0)
  input.push(0)
  input.push(0)
  input.push(@http2.H2_FRAME_DATA.to_byte())
  input.push(0)
  input.push(0)
  input.push(0)
  input.push(0)
  input.push(1)
  for byte in @http2.encode_request_frames(encoder, 3, request).unwrap() {
    input.push(byte)
  }
  let reader = @aio.MemoryReader(async fn(writer) {
    writer.write(Bytes::from_array(input))
  })
  let writer : CaptureWriter = { bytes: [] }
  let mut calls = 0
  serve_http2_connection(reader, writer, fn(_) {
    calls += 1
    {
      status: 200,
      version: Http2,
      headers: @types.HeaderMap::new(),
      body: b"ok",
    }
  })
  assert_eq(calls, 1)
  let decoder = @http2.FrameDecoder::new()
  decoder.feed(Bytes::from_array(writer.bytes)).unwrap()
  let mut saw_reset = false
  let mut saw_response = false
  while decoder.next() is Ok(Some(frame)) {
    if frame.header.typ == @http2.H2_FRAME_RST_STREAM &&
      frame.header.stream_id == 1 {
      saw_reset = true
    }
    if frame.header.typ == @http2.H2_FRAME_HEADERS &&
      frame.header.stream_id == 3 {
      saw_response = true
    }
  }
  assert_eq(saw_reset, true)
  assert_eq(saw_response, true)
}
