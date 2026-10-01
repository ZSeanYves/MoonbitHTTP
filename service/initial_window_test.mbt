///|
fn append_wire(output : Array[Byte], bytes : BytesView) -> Unit {
  for byte in bytes {
    output.push(byte)
  }
}

///|
fn early_data_frames(output : Array[Byte]) -> Unit {
  for index in 0..<80 {
    append_wire(
      output,
      @http2.encode_data_frames(
        1,
        Bytes::from_array([index.to_byte()]),
        index == 79,
      ).unwrap(),
    )
  }
  append_wire(output, Bytes::from_array(@http2.encode_settings_frame([], true)))
}

///|
fn server_sent_frame(bytes : Array[Byte], typ : Int, flags : Int) -> Bool {
  let frames = @http2.FrameDecoder::new()
  if frames.feed(Bytes::from_array(bytes)) is Err(_) {
    return false
  }
  while frames.next() is Ok(Some(frame)) {
    if frame.header.typ == typ && (frame.header.flags & flags) == flags {
      return true
    }
  }
  false
}

///|
async test "service HTTP2 server accepts small DATA frames sent before SETTINGS ACK" {
  let input = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".to_array()
  append_wire(input, Bytes::from_array(@http2.encode_settings_frame([], false)))
  let headers = @types.HeaderMap::new()
  headers.append_string("host", "example.test").unwrap()
  let request : @types.Request[Bytes] = {
    http_method: Post,
    uri: @types.Uri::parse("/echo").unwrap(),
    version: Http2,
    headers,
    body: b"",
  }
  append_wire(
    input,
    @http2.encode_request_headers(@http2.HpackContext::new(), 1, request, false).unwrap(),
  )
  let data : Array[Byte] = []
  early_data_frames(data)
  let writes : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
  let writer : SignalingCaptureWriter = { bytes: [], signal: writes, }
  let reader = @aio.MemoryReader(async fn(peer_writer) {
    peer_writer.write(Bytes::from_array(input))
    // The handler returns a lazy echo before these bytes arrive. Returning a
    // response must not mark its body consumer as finished.
    while !server_sent_frame(writer.bytes, @http2.H2_FRAME_HEADERS, 0) {
      writes.get()
    }
    peer_writer.write(Bytes::from_array(data))
    // Keep the peer open until the response body has drained the bounded queue.
    while !server_sent_frame(
            writer.bytes,
            @http2.H2_FRAME_DATA,
            @http2.H2_FLAGS_END_STREAM,
          ) {
      writes.get()
    }
  })
  let config : @service.ServerConfig = {
    ..@service.ServerConfig::defaults(),
    body_queue_capacity: 2,
    h2_receive_window_bytes: 9,
  }
  let expected = Bytes::from_array(
    Array::makei(80, fn(index) { index.to_byte() }),
  )
  @async.with_timeout(1000, async fn() {
    @service.serve_http2_connection(
      reader,
      writer,
      async fn(request) {
        @async.sleep(5)
        {
          status: 200,
          version: Http2,
          headers: @types.HeaderMap::new(),
          body: request.body,
        }
      },
      config~,
    )
  })
  let frames = @http2.FrameDecoder::new()
  frames.feed(Bytes::from_array(writer.bytes)).unwrap()
  let received : Array[Byte] = []
  while frames.next() is Ok(Some(frame)) {
    assert_true(frame.header.typ != @http2.H2_FRAME_RST_STREAM)
    if frame.header.typ == @http2.H2_FRAME_DATA {
      for byte in frame.payload {
        received.push(byte)
      }
    }
  }
  assert_eq(Bytes::from_array(received), expected)
}

///|
async test "service HTTP2 client accepts small DATA frames sent before SETTINGS ACK" {
  let input : Array[Byte] = @http2.encode_settings_frame([], false)
  let response : @types.Response[Bytes] = {
    status: 200,
    version: Http2,
    headers: @types.HeaderMap::new(),
    body: b"",
  }
  append_wire(
    input,
    @http2.encode_response_headers(
      @http2.HpackContext::new(),
      1,
      response,
      false,
    ).unwrap(),
  )
  early_data_frames(input)
  let writes : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
  let consumed : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
  let reader = @aio.MemoryReader(async fn(writer) {
    for _ in 0..<3 {
      writes.get()
    }
    writer.write(Bytes::from_array(input))
    consumed.get()
  })
  let writer : SignalingCaptureWriter = { bytes: [], signal: writes, }
  let config : @service.H2ClientConfig = {
    ..@service.H2ClientConfig::defaults(),
    body_queue_capacity: 2,
    h2_receive_window_bytes: 9,
  }
  @async.with_timeout(1000, async fn() {
    @service.with_h2_client_connection(
      reader,
      writer,
      async fn(client) {
        let headers = @types.HeaderMap::new()
        headers.append_string("host", "example.test").unwrap()
        let response = client.send({
          http_method: Get,
          uri: @types.Uri::parse("/echo").unwrap(),
          version: Http2,
          headers,
          body: @body.EmptyBody::new(),
        })
        @async.sleep(5)
        let (received, _) = @body.collect(response.body)
        assert_eq(
          received,
          Bytes::from_array(Array::makei(80, fn(index) { index.to_byte() })),
        )
        consumed.put(())
      },
      config~,
    )
  })
}
