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
  let writer = CaptureWriter::{ bytes: [], }
  let mut calls = 0
  @service.serve_http2_connection(reader, test_writer(writer), async fn(
    request,
  ) {
    calls += 1
    @async.pause()
    let response_headers = @types.HeaderMap::new()
    {
      status: 200,
      version: Http2,
      headers: response_headers,
      body: @body.FullBody::new(
        if request.uri.value == "/one" {
          b"one"
        } else {
          b"two"
        },
      ),
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
  let writer : CaptureWriter = { bytes: [], }
  @service.serve_http2_connection(reader, test_writer(writer), fn(_) {
    let body : Array[Byte] = []
    body.resize(70000, b'x')
    {
      status: 200,
      version: Http2,
      headers: @types.HeaderMap::new(),
      body: @body.FullBody::new(Bytes::from_array(body)),
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
  let writer : CaptureWriter = { bytes: [], }
  let mut calls = 0
  @service.serve_http2_connection(reader, test_writer(writer), fn(_) {
    calls += 1
    {
      status: 200,
      version: Http2,
      headers: @types.HeaderMap::new(),
      body: @body.FullBody::new(b"ok"),
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

///|
async test "HTTP/2 grants a waiting upload and rejects an unsupported expectation on its own stream" {
  let wire = H2LifecycleWriter::new()
  defer wire.signal.close()
  let incoming = @aio.MemoryReader(async fn(peer) {
    peer.write(
      b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" +
      Bytes::from_array(@http2.encode_settings_frame([], false)),
    )
    let encoder = @http2.HpackContext::new()
    let decoder = @http2.HpackContext::new()
    let read_head = async fn(id : Int32, status : Bytes, end_stream : Bool) {
      let frame = wire.wait_frame(@http2.H2_FRAME_HEADERS, id)
      assert_eq(
        (frame.header.flags & @http2.H2_FLAGS_END_STREAM) != 0,
        end_stream,
      )
      let fields = decoder.decode(Bytes::from_array(frame.payload)).unwrap()
      assert_true(fields.any(f => f.name == ":status" && f.value == status))
    }
    for
      (id, expectation, status) in [
        (1, "custom", b"417"),
        (3, "100-continue", b"100"),
      ] {
      let request = security_request(Post)
      request.headers.append_string("expect", expectation).unwrap()
      if expectation == "100-continue" {
        assert_true(
          @http2.encode_request_frames(
            encoder,
            id,
            request.map_body(fn(_) { b"" }),
          )
          is Err(StreamError(_, ProtocolError, _)),
        )
      }
      peer.write(
        @http2.encode_request_headers(encoder, id, request, false).unwrap(),
      )
      let rejected = id == 1
      read_head(id, status, rejected)
      peer.write(
        @http2.encode_data_frames(id, if rejected { b"" } else { b"ok" }, true).unwrap(),
      )
      if !rejected {
        read_head(id, b"204", true)
      }
    }
  })
  defer incoming.close()
  let received : Array[Bytes] = []
  @async.with_timeout(2000, async fn() {
    @service.serve_http2_connection(incoming, test_writer(wire), async fn(
      request,
    ) {
      received.push(@body.collect(request.body).0)
      {
        status: 204,
        version: Http2,
        headers: @types.HeaderMap::new(),
        body: @body.EmptyBody::new(),
      }
    })
  })
  assert_eq(received, [b"ok"])
}

///|
async test "HTTP/2 drain refuses a racing stream on the wire while stream one finishes" {
  let shutdown = @service.ServerShutdown::new()
  let entered : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
  let finish : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
  let wire = H2LifecycleWriter::new()
  defer wire.signal.close()
  let incoming = @aio.MemoryReader(async fn(peer) {
    let encoder = @http2.HpackContext::new()
    let headers = fn(id) {
      @http2.encode_request_headers(encoder, id, security_request(Get), true).unwrap()
    }
    peer.write(
      b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" +
      Bytes::from_array(@http2.encode_settings_frame([], false)) +
      headers(1),
    )
    entered.get()
    shutdown.begin()
    let goaway = wire.wait_frame(@http2.H2_FRAME_GOAWAY, 0)
    assert_eq(
      Bytes::from_array(goaway.payload),
      b"\x00\x00\x00\x01\x00\x00\x00\x00",
    )
    peer.write(headers(3))
    let refused = wire.wait_frame(@http2.H2_FRAME_RST_STREAM, 3)
    assert_eq(Bytes::from_array(refused.payload), b"\x00\x00\x00\x07")
    finish.put(())
    let response = wire.wait_frame(@http2.H2_FRAME_HEADERS, 1)
    assert_true((response.header.flags & @http2.H2_FLAGS_END_STREAM) != 0)
    let probe = wire.wait_frame(@http2.H2_FRAME_PING, 0)
    peer.write(@http2.encode_ping_ack(probe.payload).unwrap())
  })
  defer incoming.close()
  let mut calls = 0
  @async.with_timeout(2000, async fn() {
    @service.serve_http2_connection(
      incoming,
      test_writer(wire),
      async fn(_) {
        calls += 1
        entered.put(())
        finish.get()
        {
          status: 204,
          version: Http2,
          headers: @types.HeaderMap::new(),
          body: @body.EmptyBody::new(),
        }
      },
      shutdown=Some(shutdown),
    )
  })
  assert_eq(calls, 1)
}
