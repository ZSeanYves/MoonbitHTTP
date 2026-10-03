///|
struct SecurityCaptureWriter {
  bytes : Array[Byte]
  ready : @aqueue.Queue[Unit]
  mut writes : Int
}

///|
impl @aio.Writer for SecurityCaptureWriter with fn write_once(
  self,
  data,
  offset~,
  len~,
) {
  for index in offset..<(offset + len) {
    self.bytes.push(data[index])
  }
  self.writes += 1
  if self.writes == 3 {
    ignore(self.ready.try_put(()))
  }
  len
}

///|
fn security_h2_response_head(
  status : Int,
  content_length : String?,
  end_stream : Bool,
) -> Bytes {
  let headers = @types.HeaderMap::new()
  if content_length is Some(value) {
    headers.append_string("content-length", value).unwrap()
  }
  @http2.encode_response_headers(
    @http2.HpackContext::new(),
    1,
    { status, version: Http2, headers, body: (), },
    end_stream,
  ).unwrap()
}

///|
async fn security_h2_response(
  frames : Bytes,
  consume : async (@service.H2Client) -> Unit,
  max_body_bytes? : Int = 64,
) -> Unit {
  let ready : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
  let reader = @aio.MemoryReader(async fn(writer) {
    ready.get()
    writer.write(Bytes::from_array(@http2.encode_settings_frame([], false)))
    writer.write(frames)
    // Keep the peer side alive while the client publishes a stream error and
    // releases the stream; an immediate EOF would turn that expected error
    // into a connection-level failure in the harness.
    @async.sleep(100)
  })
  let writer : SecurityCaptureWriter = { bytes: [], ready, writes: 0, }
  let limits = { ..@types.Limits::defaults(), max_body_bytes, }
  @async.with_timeout(1000, async fn() {
    @service.with_h2_client_connection(reader, writer, consume, config={
      ..@service.H2ClientConfig::defaults(),
      limits,
      body_queue_capacity: 1,
    })
  })
}

///|
fn security_request(
  http_method : @types.Method,
) -> @types.Request[@body.EmptyBody] {
  let headers = @types.HeaderMap::new()
  headers.append_string("host", "example.test").unwrap()
  {
    http_method,
    uri: @types.Uri::parse("/").unwrap(),
    version: Http2,
    headers,
    body: @body.EmptyBody::new(),
  }
}

///|
async fn security_expect_h2_failure(
  frames : Bytes,
  expected : @http2.H2ErrorCode,
  http_method? : @types.Method = Get,
  max_body_bytes? : Int = 64,
) -> Unit {
  security_h2_response(
    frames,
    async fn(client) {
      try {
        let response = client.send(security_request(http_method))
        // Deliberately larger than the protocol cap: the protocol must reject
        // an oversized stream even when the downstream collector permits it.
        ignore(@body.collect(response.body, max_bytes=1024))
      } catch {
        @http2.H2ProtocolError::StreamError(1, code, _) =>
          assert_eq(code, expected)
        _ => fail("unexpected HTTP/2 failure")
      } noraise {
        _ => fail("malformed or oversized response was accepted")
      }
    },
    max_body_bytes~,
  )
}

///|
async test "service HTTP/1 EOF before final headers is terminal" {
  for prefix in [b"", b"HTTP/1.1 100 Continue\r\n\r\n"] {
    let reader = @aio.MemoryReader(async fn(writer) { writer.write(prefix) })
    let ready : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
    let writer : SecurityCaptureWriter = { bytes: [], ready, writes: 0, }
    let client = @service.ClientConnection::new(reader, writer).unwrap()
    let request = { ..security_request(Get), version: Http11, }
    try
      @async.with_timeout(1000, async fn() { ignore(client.send(request)) })
    catch {
      @http1.Http1Error::UnexpectedEof(_) => ()
      error => fail("unexpected pre-response EOF failure: \{error}")
    } noraise {
      _ => fail("EOF before final response headers was accepted")
    }
    assert_true(client.is_closed())
  }
}

///|
async test "service HTTP/2 rejects DATA before final response headers without stranding send" {
  security_expect_h2_failure(
    @http2.encode_data_frames(1, b"", true).unwrap(),
    ProtocolError,
  )
  security_expect_h2_failure(
    security_h2_response_head(103, None, false) +
    @http2.encode_data_frames(1, b"x", true).unwrap(),
    ProtocolError,
  )
}

///|
async test "service HTTP/2 bounds cumulative response data with and without content-length" {
  let body = @http2.encode_data_frames(1, b"ab", false).unwrap() +
    @http2.encode_data_frames(1, b"cd", false).unwrap() +
    @http2.encode_data_frames(1, b"e", true).unwrap()
  security_expect_h2_failure(
    security_h2_response_head(200, None, false) + body,
    EnhanceYourCalm,
    max_body_bytes=4,
  )
  security_expect_h2_failure(
    security_h2_response_head(200, Some("5"), false) + body,
    EnhanceYourCalm,
    max_body_bytes=4,
  )
  security_h2_response(
    security_h2_response_head(200, Some("4"), false) +
    @http2.encode_data_frames(1, b"ab", false).unwrap() +
    @http2.encode_data_frames(1, b"cd", true).unwrap(),
    async fn(client) {
      let response = client.send(security_request(Get))
      let (bytes, _) = @body.collect(response.body)
      assert_eq(bytes, b"abcd")
    },
    max_body_bytes=4,
  )
}

///|
async test "service HTTP/2 validates response length and body-forbidden semantics" {
  security_expect_h2_failure(
    security_h2_response_head(200, Some("1"), true),
    ProtocolError,
  )
  security_expect_h2_failure(
    security_h2_response_head(200, Some("2"), false) +
    @http2.encode_data_frames(1, b"x", true).unwrap(),
    ProtocolError,
  )
  security_expect_h2_failure(
    security_h2_response_head(200, Some("1"), false) +
    @http2.encode_data_frames(1, b"xx", true).unwrap(),
    ProtocolError,
  )
  security_expect_h2_failure(
    security_h2_response_head(200, Some("1"), false) +
    @http2.encode_data_frames(1, b"x", true).unwrap(),
    ProtocolError,
    http_method=Head,
  )
  security_expect_h2_failure(
    security_h2_response_head(204, Some("0"), true),
    ProtocolError,
  )
  for (http_method, status) in [(@types.Method::Head, 200), (Get, 304)] {
    security_h2_response(
      security_h2_response_head(status, Some("1000"), true),
      async fn(client) {
        let response = client.send(security_request(http_method))
        assert_true(response.body.next_frame() is None)
      },
      max_body_bytes=4,
    )
  }
}

///|
async test "service HTTP/2 rejects response frames after trailers" {
  let trailer_headers = @types.HeaderMap::new()
  trailer_headers.append_string("x-end", "yes").unwrap()
  let response = security_h2_response_head(200, None, false) +
    @http2.encode_data_frames(1, b"first", false).unwrap() +
    @http2.encode_data_frames(1, b"second", false).unwrap() +
    @http2.encode_trailers(@http2.HpackContext::new(), 1, trailer_headers).unwrap() +
    @http2.encode_data_frames(1, b"late", true).unwrap()
  let ready : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
  let reader = @aio.MemoryReader(async fn(writer) {
    ready.get()
    writer.write(Bytes::from_array(@http2.encode_settings_frame([], false)))
    writer.write(response)
    // Allow the reader pump to publish the reset before the connection scope
    // closes.  The trailers remain terminal even if their body queue drains.
    @async.sleep(50)
  })
  let writer : SecurityCaptureWriter = { bytes: [], ready, writes: 0, }
  @async.with_timeout(1000, async fn() {
    @service.with_h2_client_connection(
      reader,
      writer,
      async fn(client) {
        let result = client.send(security_request(Get))
        assert_eq(result.status, 200)
        @async.sleep(100)
      },
      config={ ..@service.H2ClientConfig::defaults(), body_queue_capacity: 1, },
    )
  })
  let encoded = Bytes::from_array(writer.bytes[24:].to_owned())
  let decoder = @http2.FrameDecoder::new()
  decoder.feed(encoded).unwrap()
  let mut saw_reset = false
  while decoder.next() is Ok(Some(frame)) {
    if frame.header.typ == @http2.H2_FRAME_RST_STREAM &&
      frame.header.stream_id == 1 {
      saw_reset = true
    }
  }
  assert_true(saw_reset)
}

///|
async test "service HTTP/2 rejects DATA and duplicate trailers after request end" {
  let encoder = @http2.HpackContext::new()
  let headers = @types.HeaderMap::new()
  headers.append_string("host", "example.test").unwrap()
  let request : @types.Request[Bytes] = {
    http_method: Post,
    uri: @types.Uri::parse("/").unwrap(),
    version: Http2,
    headers,
    body: b"x",
  }
  let request_headers = @http2.encode_request_headers(
    encoder, 1, request, false,
  ).unwrap()
  let trailers = @types.HeaderMap::new()
  trailers.append_string("x-end", "yes").unwrap()
  let request_trailers = @http2.encode_trailers(encoder, 1, trailers).unwrap()
  let duplicate_trailers = @http2.encode_trailers(
    encoder,
    1,
    @types.HeaderMap::new(),
  ).unwrap()
  let bytes = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" +
    Bytes::from_array(@http2.encode_settings_frame([], false)) +
    request_headers +
    request_trailers +
    duplicate_trailers +
    @http2.encode_data_frames(1, b"late", true).unwrap()
  let reader = @aio.MemoryReader(async fn(writer) { writer.write(bytes) })
  let writer : CaptureWriter = { bytes: [], }
  @async.with_timeout(1000, async fn() {
    @service.serve_http2_connection(reader, writer, async fn(_) {
      @async.sleep(1000)
      {
        status: 200,
        version: Http2,
        headers: @types.HeaderMap::new(),
        body: @body.EmptyBody::new(),
      }
    })
  })
  let decoder = @http2.FrameDecoder::new()
  decoder.feed(Bytes::from_array(writer.bytes)).unwrap()
  let mut saw_reset = false
  while decoder.next() is Ok(Some(frame)) {
    if frame.header.typ == @http2.H2_FRAME_RST_STREAM &&
      frame.header.stream_id == 1 {
      saw_reset = true
    }
  }
  assert_true(saw_reset)
}

///|
async test "service HTTP/2 rapid resets cancel and join handlers before reusing admission" {
  let started : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
  let encoder = @http2.HpackContext::new()
  let reader = @aio.MemoryReader(async fn(writer) {
    writer.write(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
    writer.write(Bytes::from_array(@http2.encode_settings_frame([], false)))
    for id in [1, 3, 5, 7] {
      writer.write(
        @http2.encode_request_headers(encoder, id, security_request(Get), true).unwrap(),
      )
      started.get()
      writer.write(@http2.encode_rst_stream(id, Cancel).unwrap())
    }
  })
  let ready : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
  let writer : SecurityCaptureWriter = { bytes: [], ready, writes: 0, }
  let mut active = 0
  let mut peak = 0
  let mut finished = 0
  let limits = { ..@types.Limits::defaults(), max_concurrent_requests: 1, }
  @async.with_timeout(1000, async fn() {
    @service.serve_http2_connection(
      reader,
      writer,
      async fn(_) {
        active += 1
        peak = peak.max(active)
        defer @async.protect_from_cancel(async fn() {
          // Model asynchronous handler cleanup. Admission must stay occupied
          // until this finishes, even though the peer already reset its stream.
          @async.sleep(1)
          active -= 1
          finished += 1
        })
        started.put(())
        @async.sleep(60_000)
        {
          status: 200,
          version: Http2,
          headers: @types.HeaderMap::new(),
          body: @body.EmptyBody::new(),
        }
      },
      config={ ..@service.ServerConfig::defaults(), limits, },
    )
  })
  assert_eq(peak, 1)
  assert_eq(active, 0)
  assert_eq(finished, 4)
}
