///|
async test "security HPACK: refused and closed request blocks preserve dynamic state" {
  for closed_stream in [false, true] {
    for fragmented in [false, true] {
      let encoder = @http2.HpackContext::new()
      let writer = H2LifecycleWriter::new()
      let started : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
      let stopped : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
      let first = security_request(Get)
      let first = { ..first, uri: @types.Uri::parse("/hold").unwrap(), }
      let repeated = security_request(Get)
      repeated.headers
      .append_string("x-discarded", "retained-compression-state")
      .unwrap()
      let reader = @aio.MemoryReader(async fn(peer) {
        peer.write(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
        peer.write(Bytes::from_array(@http2.encode_settings_frame([], false)))
        peer.write(
          @http2.encode_request_headers(encoder, 1, first, true).unwrap(),
        )
        started.get()
        if closed_stream {
          peer.write(@http2.encode_rst_stream(1, Cancel).unwrap())
          stopped.get()
        }
        let discarded_id = if closed_stream { 1 } else { 3 }
        peer.write(
          @http2.encode_request_headers(
            encoder,
            discarded_id,
            repeated,
            true,
            max_frame_size=if fragmented { 1 } else { 16384 },
          ).unwrap(),
        )
        ignore(writer.wait_frame(@http2.H2_FRAME_RST_STREAM, discarded_id))
        if !closed_stream {
          peer.write(@http2.encode_rst_stream(1, Cancel).unwrap())
          stopped.get()
        }
        peer.write(
          @http2.encode_request_headers(encoder, 5, repeated, true).unwrap(),
        )
        ignore(writer.wait_frame(@http2.H2_FRAME_HEADERS, 5))
      })
      let mut calls = 0
      @async.with_timeout(1000, async fn() {
        @service.serve_http2_connection(
          reader,
          writer,
          async fn(request) {
            calls += 1
            if request.uri.value == "/hold" {
              defer ignore(stopped.try_put(()) catch { _ => false })
              started.put(())
              @async.sleep(60_000)
            }
            assert_eq(
              request.headers
              .get_string("x-discarded")
              .unwrap()
              .to_string_lossy(),
              "retained-compression-state",
            )
            {
              status: 200,
              version: Http2,
              headers: @types.HeaderMap::new(),
              body: @body.EmptyBody::new(),
            }
          },
          config={
            ..@service.ServerConfig::defaults(),
            limits: { ..@types.Limits::defaults(), max_concurrent_requests: 1, },
          },
        )
      })
      assert_eq(calls, 2)
    }
  }
}

///|
async test "security HPACK: client decodes closed-stream headers before live response" {
  for fragmented in [false, true] {
    let encoder = @http2.HpackContext::new()
    let writer = H2LifecycleWriter::new()
    let ready : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
    let reset_done : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
    let finished : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
    let plain : @types.Response[Bytes] = {
      status: 200,
      version: Http2,
      headers: @types.HeaderMap::new(),
      body: b"",
    }
    let headers = @types.HeaderMap::new()
    headers.append_string("x-discarded", "client-state").unwrap()
    let repeated = { ..plain, headers, }
    let reader = @aio.MemoryReader(async fn(peer) {
      peer.write(Bytes::from_array(@http2.encode_settings_frame([], false)))
      ignore(writer.wait_frame(@http2.H2_FRAME_HEADERS, 1))
      peer.write(
        @http2.encode_response_headers(encoder, 1, plain, true).unwrap(),
      )
      ready.get()
      peer.write(
        @http2.encode_response_headers(
          encoder,
          1,
          repeated,
          true,
          max_frame_size=if fragmented { 1 } else { 16384 },
        ).unwrap(),
      )
      ignore(writer.wait_frame(@http2.H2_FRAME_RST_STREAM, 1))
      reset_done.put(())
      ignore(writer.wait_frame(@http2.H2_FRAME_HEADERS, 3))
      peer.write(
        @http2.encode_response_headers(encoder, 3, repeated, true).unwrap(),
      )
      finished.get()
    })
    @async.with_timeout(1000, async fn() {
      @service.with_h2_client_connection(reader, writer, async fn(client) {
        let first = client.send(security_request(Get))
        ignore(@body.collect(first.body))
        ready.put(())
        reset_done.get()
        let second = client.send(security_request(Get))
        assert_eq(
          second.headers.get_string("x-discarded").unwrap().to_string_lossy(),
          "client-state",
        )
        ignore(@body.collect(second.body))
        finished.put(())
      })
    })
  }
}
