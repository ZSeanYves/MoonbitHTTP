///|
fn captured_h2_frame(bytes : Array[Byte], typ : Int, flags : Int) -> Bool {
  if bytes.length() < 24 {
    return false
  }
  let frames = @http2.FrameDecoder::new()
  if frames.feed(Bytes::from_array(bytes)[24:]) is Err(_) {
    return false
  }
  while frames.next() is Ok(Some(frame)) {
    if frame.header.typ == typ && frame.header.flags == flags {
      return true
    }
  }
  false
}

///|
async test "service: HTTP/2 client applies peer table limit before sending request headers" {
  let writes : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
  let ready : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
  let writer : SignalingCaptureWriter = { bytes: [], signal: writes, }
  let reader = @aio.MemoryReader(async fn(peer_writer) {
    peer_writer.write(
      Bytes::from_array(
        @http2.encode_settings_frame([{ id: 1, value: 0, }], false),
      ),
    )
    while !captured_h2_frame(
            writer.bytes,
            @http2.H2_FRAME_SETTINGS,
            @http2.H2_FLAGS_ACK,
          ) {
      writes.get()
    }
    ready.put(())
    while !captured_h2_frame(
            writer.bytes,
            @http2.H2_FRAME_HEADERS,
            @http2.H2_FLAGS_END_HEADERS | @http2.H2_FLAGS_END_STREAM,
          ) {
      writes.get()
    }
    let response : @types.Response[Bytes] = {
      status: 200,
      version: Http2,
      headers: @types.HeaderMap::new(),
      body: b"",
    }
    peer_writer.write(
      @http2.encode_response_frames(@http2.HpackContext::new(), 1, response).unwrap(),
    )
  })
  let config : @service.H2ClientConfig = {
    ..@service.H2ClientConfig::defaults(),
    limits: { ..@types.Limits::defaults(), max_dynamic_table_bytes: 1024, },
  }
  @async.with_timeout(1000, async fn() {
    @service.with_h2_client_connection(
      reader,
      writer,
      async fn(client) {
        ready.get()
        let headers = @types.HeaderMap::new()
        headers.append_string("host", "example.test").unwrap()
        headers.append_string("x-custom", "value").unwrap()
        let response = client.send({
          http_method: Get,
          uri: @types.Uri::parse("/settings").unwrap(),
          version: Http2,
          headers,
          body: @body.EmptyBody::new(),
        })
        assert_eq(response.status, 200)
      },
      config~,
    )
  })
  let frames = @http2.FrameDecoder::new()
  frames.feed(Bytes::from_array(writer.bytes)[24:]).unwrap()
  let decoder = @http2.HpackContext::new(max_table_size=0)
  let mut checked = false
  let mut advertised = false
  while frames.next() is Ok(Some(frame)) {
    if frame.header.typ == @http2.H2_FRAME_SETTINGS && frame.header.flags == 0 {
      assert_true(
        Bytes::from_array(frame.payload).has_prefix(b"\x00\x01\x00\x00\x04\x00"),
      )
      advertised = true
    }
    if frame.header.typ == @http2.H2_FRAME_HEADERS {
      assert_eq(frame.payload[0], b'\x20')
      let fields = decoder.decode(Bytes::from_array(frame.payload)).unwrap()
      assert_true(
        fields.any(fn(field) {
          field.name == "x-custom" && field.value == b"value"
        }),
      )
      checked = true
    }
  }
  assert_true(checked)
  assert_true(advertised)
  assert_eq(decoder.table_length(), 0)
}

///|
async test "service: HTTP/2 server applies peer table limit only to response encoder" {
  let input : Array[Byte] = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".to_array()
  for byte in @http2.encode_settings_frame([{ id: 1, value: 0, }], false) {
    input.push(byte)
  }
  let encoder = @http2.HpackContext::new()
  let headers = @types.HeaderMap::new()
  headers.append_string("host", "example.test").unwrap()
  headers.append_string("x-repeat", "value").unwrap()
  // The second request uses dynamic indices; the receiving table must stay
  // enabled although the peer disabled the opposite direction's table.
  for id in [1, 3] {
    let request : @types.Request[Bytes] = {
      http_method: Get,
      uri: @types.Uri::parse("/repeat").unwrap(),
      version: Http2,
      headers,
      body: b"",
    }
    for byte in @http2.encode_request_frames(encoder, id, request).unwrap() {
      input.push(byte)
    }
  }
  let reader = @aio.MemoryReader(async fn(writer) {
    writer.write(Bytes::from_array(input))
  })
  let writer : CaptureWriter = { bytes: [], }
  let mut calls = 0
  let config : @service.ServerConfig = {
    ..@service.ServerConfig::defaults(),
    limits: { ..@types.Limits::defaults(), max_dynamic_table_bytes: 1024, },
  }
  @service.serve_http2_connection(
    reader,
    writer,
    fn(_) {
      calls += 1
      let response_headers = @types.HeaderMap::new()
      response_headers.append_string("x-repeat", "value").unwrap()
      {
        status: 200,
        version: Http2,
        headers: response_headers,
        body: @body.EmptyBody::new(),
      }
    },
    config~,
  )
  assert_eq(calls, 2)
  let frames = @http2.FrameDecoder::new()
  frames.feed(Bytes::from_array(writer.bytes)).unwrap()
  let decoder = @http2.HpackContext::new(max_table_size=0)
  let mut checked = 0
  let mut advertised = false
  while frames.next() is Ok(Some(frame)) {
    if frame.header.typ == @http2.H2_FRAME_SETTINGS && frame.header.flags == 0 {
      assert_true(
        Bytes::from_array(frame.payload).has_prefix(b"\x00\x01\x00\x00\x04\x00"),
      )
      advertised = true
    }
    if frame.header.typ == @http2.H2_FRAME_HEADERS {
      let fields = decoder.decode(Bytes::from_array(frame.payload)).unwrap()
      assert_true(
        fields.any(fn(field) {
          field.name == "x-repeat" && field.value == b"value"
        }),
      )
      checked += 1
    }
  }
  assert_eq(checked, 2)
  assert_true(advertised)
  assert_eq(decoder.table_length(), 0)
}
