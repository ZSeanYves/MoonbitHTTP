///|
struct H2LifecycleWriter {
  decoder : @http2.FrameDecoder
  frames : Array[@http2.H2Frame]
  signal : @aqueue.Queue[@http2.H2Frame]
}

///|
fn H2LifecycleWriter::new() -> H2LifecycleWriter {
  {
    decoder: @http2.FrameDecoder::new(),
    frames: [],
    signal: Queue(kind=Unbounded),
  }
}

///|
impl @aio.Writer for H2LifecycleWriter with fn write_once(
  self,
  data,
  offset~,
  len~,
) {
  let bytes = data[offset:offset + len].to_owned()
  if bytes != b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" {
    self.decoder.feed(bytes).unwrap()
    while self.decoder.next().unwrap() is Some(frame) {
      self.frames.push(frame)
      self.signal.put(frame)
    }
  }
  len
}

///|
async fn H2LifecycleWriter::wait_frame(
  self : H2LifecycleWriter,
  typ : Int,
  stream_id : Int,
) -> @http2.H2Frame {
  for ;; {
    let frame = self.signal.get()
    if frame.header.typ == typ && frame.header.stream_id == stream_id {
      return frame
    }
  }
}

///|
fn H2LifecycleWriter::connection_credit(self : H2LifecycleWriter) -> Int {
  let mut total = 0
  for frame in self.frames {
    if frame.header.typ == @http2.H2_FRAME_WINDOW_UPDATE &&
      frame.header.stream_id == 0 {
      total += ((frame.payload[0].to_int() & 0x7f) << 24) |
        (frame.payload[1].to_int() << 16) |
        (frame.payload[2].to_int() << 8) |
        frame.payload[3].to_int()
    }
  }
  total
}

///|
fn h2_lifecycle_ping() -> Bytes {
  // A round trip establishes that every preceding input frame was processed.
  Bytes::from_array([0, 0, 8, 6, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8])
}

///|
struct H2GatedWriter {
  control : H2LifecycleWriter
  started : @aqueue.Queue[Unit]
  release : @aqueue.Queue[Unit]
  typ : Int
  stream_id : Int
  mut held : Bool
}

///|
impl @aio.Writer for H2GatedWriter with fn write_once(self, data, offset~, len~) {
  let bytes = data[offset:offset + len].to_owned()
  if !self.held &&
    len >= 9 &&
    bytes[3].to_int() == self.typ &&
    bytes[8].to_int() == self.stream_id {
    self.held = true
    self.started.put(())
    self.release.get()
  }
  @aio.Writer::write_once(self.control, data, offset~, len~)
}

///|
async test "H2 client consumption credit survives cancellation while another writer holds the lock" {
  let writer : H2GatedWriter = {
    control: H2LifecycleWriter::new(),
    started: Queue(kind=Blocking(1)),
    release: Queue(kind=Blocking(1)),
    typ: @http2.H2_FRAME_PING,
    stream_id: 0,
    held: false,
  }
  defer writer.control.signal.close()
  let done : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
  defer done.close()
  let reader = @aio.MemoryReader(async fn(peer) {
    ignore(writer.control.wait_frame(@http2.H2_FRAME_HEADERS, 1))
    peer.write(Bytes::from_array(@http2.encode_settings_frame([], false)))
    peer.write(security_h2_response_head(200, None, false))
    peer.write(@http2.encode_data_frames(1, b"abc", false).unwrap())
    peer.write(h2_lifecycle_ping())
    ignore(writer.control.wait_frame(@http2.H2_FRAME_HEADERS, 3))
    peer.write(
      @http2.encode_response_headers(
        @http2.HpackContext::new(),
        3,
        {
          status: 204,
          version: Http2,
          headers: @types.HeaderMap::new(),
          body: (),
        },
        true,
      ).unwrap(),
    )
    done.get()
  })
  defer reader.close()
  @async.with_timeout(1000, async fn() {
    @service.with_h2_client_connection(reader, writer, async fn(client) {
      let response = client.send(security_request(Get))
      writer.started.get()
      @async.with_task_group(async fn(group) {
        let started : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
        let consumer = group.spawn(async fn() {
          errdefer response.body.cancel(@body.BodyError::Cancelled)
          started.put(())
          ignore(response.body.next_frame())
          @async.sleep(60_000)
        })
        started.get()
        @async.pause()
        consumer.cancel()
        @async.pause()
        writer.release.put(())
        consumer.wait() catch {
          @async.WaitedTaskAlreadyCancelled => ()
          _ => ()
        }
      })
      assert_eq(client.send(security_request(Get)).status, 204)
      assert_eq(writer.control.connection_credit(), 3)
      done.put(())
    })
  })
}

///|
async test "H2 server consumption credit survives handler cancellation while another writer holds the lock" {
  let writer : H2GatedWriter = {
    control: H2LifecycleWriter::new(),
    started: Queue(kind=Blocking(1)),
    release: Queue(kind=Blocking(1)),
    typ: @http2.H2_FRAME_HEADERS,
    stream_id: 3,
    held: false,
  }
  defer writer.control.signal.close()
  let consume : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
  let reader = @aio.MemoryReader(async fn(peer) {
    peer.write(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
    peer.write(Bytes::from_array(@http2.encode_settings_frame([], false)))
    let encoder = @http2.HpackContext::new()
    peer.write(
      @http2.encode_request_headers(encoder, 1, security_request(Post), false).unwrap(),
    )
    peer.write(@http2.encode_data_frames(1, b"abc", false).unwrap())
    peer.write(
      @http2.encode_request_headers(encoder, 3, security_request(Get), true).unwrap(),
    )
    writer.started.get()
    consume.put(())
    @async.pause()
    peer.write(@http2.encode_rst_stream(1, Cancel).unwrap())
    @async.pause()
    writer.release.put(())
    let response = writer.control.wait_frame(@http2.H2_FRAME_DATA, 3)
    assert_eq(Bytes::from_array(response.payload), b"ok")
    ignore(writer.control.wait_frame(@http2.H2_FRAME_DATA, 3))
    peer.write(h2_lifecycle_ping())
    ignore(writer.control.wait_frame(@http2.H2_FRAME_PING, 0))
  })
  defer reader.close()
  @async.with_timeout(1000, async fn() {
    @service.serve_http2_connection(reader, writer, async fn(request) {
      if request.http_method == Post {
        consume.get()
        ignore(request.body.next_frame())
        @async.sleep(60_000)
      }
      {
        status: 200,
        version: Http2,
        headers: @types.HeaderMap::new(),
        body: @body.FullBody::new(b"ok"),
      }
    })
  })
  assert_eq(writer.control.connection_credit(), 3)
}

///|
struct H2InterruptedWriter {
  control : H2LifecycleWriter
  started : @aqueue.Queue[Unit]
  captured : Array[Byte]
  mut state : Int
}

///|
impl @aio.Writer for H2InterruptedWriter with fn write_once(
  self,
  data,
  offset~,
  len~,
) {
  let bytes = data[offset:offset + len].to_owned()
  if self.state == 0 && len >= 9 && bytes[3] == 0 {
    self.captured.append(bytes[:9].to_array())
    self.state = 1
    return 9
  }
  if self.state == 1 {
    self.started.put(())
    errdefer {
      self.state = 2
    }
    @async.sleep(60_000)
  }
  self.captured.append(bytes.to_array())
  @aio.Writer::write_once(self.control, data, offset~, len~)
}

///|
async test "H2 interrupted upload frame closes connection before another frame is written" {
  let writer : H2InterruptedWriter = {
    control: H2LifecycleWriter::new(),
    started: Queue(kind=Blocking(1)),
    captured: [],
    state: 0,
  }
  defer writer.control.signal.close()
  let closed : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
  let upload = @body.BodyStream::new().unwrap()
  let reader = @aio.MemoryReader(async fn(peer) {
    ignore(writer.control.wait_frame(@http2.H2_FRAME_HEADERS, 1))
    peer.write(Bytes::from_array(@http2.encode_settings_frame([], false)))
    peer.write(security_h2_response_head(200, None, false))
    @async.sleep(60_000)
  })
  defer reader.close()
  @async.with_timeout(1000, async fn() {
    @service.with_h2_client_connection(
      reader,
      writer,
      async fn(client) {
        let response = client.send(
          security_request(Post).map_body(fn(_) { upload }),
        )
        upload.push(Data(b"payload"))
        writer.started.get()
        let before = writer.captured.length()
        response.body.cancel(@body.BodyError::Cancelled)
        closed.get()
        try client.send(security_request(Get)) catch {
          @http2.H2ProtocolError::ConnectionError(_, _) => ()
          error => raise error
        } noraise {
          _ => fail("interrupted HTTP/2 frame left the connection open")
        }
        assert_eq(writer.captured.length(), before)
      },
      config={
        ..@service.H2ClientConfig::defaults(),
        close_callback: Some(fn(_) {
          ignore(closed.try_put(()) catch { _ => false })
        }),
      },
    )
  })
}

///|
async test "H2 response cancellation refunds blocked and terminal bodies and preserves other streams" {
  for terminal in [false, true] {
    let writer = H2LifecycleWriter::new()
    defer writer.signal.close()
    let received : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
    let refunded : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
    let done : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
    defer done.close()
    let reader = @aio.MemoryReader(async fn(peer) {
      ignore(writer.wait_frame(@http2.H2_FRAME_HEADERS, 1))
      peer.write(Bytes::from_array(@http2.encode_settings_frame([], false)))
      peer.write(security_h2_response_head(200, Some("3"), false))
      peer.write(@http2.encode_data_frames(1, b"a", false).unwrap())
      peer.write(@http2.encode_data_frames(1, b"bc", terminal).unwrap())
      peer.write(h2_lifecycle_ping())
      ignore(writer.wait_frame(@http2.H2_FRAME_PING, 0))
      received.put(())
      ignore(writer.wait_frame(@http2.H2_FRAME_WINDOW_UPDATE, 0))
      assert_eq(writer.connection_credit(), 3)
      refunded.put(())
      ignore(writer.wait_frame(@http2.H2_FRAME_HEADERS, 3))
      let response : @types.Response[Unit] = {
        status: 204,
        version: Http2,
        headers: @types.HeaderMap::new(),
        body: (),
      }
      peer.write(
        @http2.encode_response_headers(
          @http2.HpackContext::new(),
          3,
          response,
          true,
        ).unwrap(),
      )
      done.get()
    })
    defer reader.close()
    @async.with_timeout(1000, async fn() {
      @service.with_h2_client_connection(
        reader,
        writer,
        async fn(client) {
          let response = client.send(security_request(Get))
          received.get()
          response.body.cancel(@body.BodyError::Cancelled)
          response.body.cancel(@body.BodyError::Cancelled)
          refunded.get()
          assert_eq(client.send(security_request(Get)).status, 204)
          assert_eq(writer.connection_credit(), 3)
          done.put(())
        },
        config={
          ..@service.H2ClientConfig::defaults(),
          body_queue_capacity: if terminal {
            2
          } else {
            1
          },
        },
      )
    })
  }
}

///|
async test "H2 request cancellation drains credit while preserving an early response" {
  let writer = H2LifecycleWriter::new()
  defer writer.signal.close()
  let received : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
  let reader = @aio.MemoryReader(async fn(peer) {
    peer.write(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
    peer.write(Bytes::from_array(@http2.encode_settings_frame([], false)))
    peer.write(
      @http2.encode_request_headers(
        @http2.HpackContext::new(),
        1,
        security_request(Post),
        false,
      ).unwrap(),
    )
    peer.write(@http2.encode_data_frames(1, b"ab", false).unwrap())
    peer.write(h2_lifecycle_ping())
    ignore(writer.wait_frame(@http2.H2_FRAME_PING, 0))
    received.put(())
    ignore(writer.wait_frame(@http2.H2_FRAME_WINDOW_UPDATE, 0))
    peer.write(@http2.encode_data_frames(1, b"cd", true).unwrap())
    let response = writer.wait_frame(@http2.H2_FRAME_DATA, 1)
    assert_eq(Bytes::from_array(response.payload), b"ok")
    ignore(writer.wait_frame(@http2.H2_FRAME_DATA, 1))
    peer.write(h2_lifecycle_ping())
    ignore(writer.wait_frame(@http2.H2_FRAME_PING, 0))
  })
  defer reader.close()
  @async.with_timeout(1000, async fn() {
    @service.serve_http2_connection(
      reader,
      writer,
      async fn(request) {
        received.get()
        request.body.cancel(@body.BodyError::Cancelled)
        {
          status: 200,
          version: Http2,
          headers: @types.HeaderMap::new(),
          body: @body.FullBody::new(b"ok"),
        }
      },
      config={ ..@service.ServerConfig::defaults(), body_queue_capacity: 1, },
    )
  })
  assert_eq(writer.connection_credit(), 4)
}

///|
async test "H2 response cancellation stops an upload waiting for source data" {
  let writer = H2LifecycleWriter::new()
  defer writer.signal.close()
  let mut source_cancellations = 0
  let upload = @body.BodyStream::new(on_cancel=fn(_) {
    source_cancellations += 1
  }).unwrap()
  let reader = @aio.MemoryReader(async fn(peer) {
    ignore(writer.wait_frame(@http2.H2_FRAME_HEADERS, 1))
    peer.write(Bytes::from_array(@http2.encode_settings_frame([], false)))
    peer.write(security_h2_response_head(200, None, false))
    @async.sleep(60_000)
  })
  defer reader.close()
  @async.with_timeout(1000, async fn() {
    @service.with_h2_client_connection(reader, writer, async fn(client) {
      let response = client.send(
        security_request(Post).map_body(fn(_) { upload }),
      )
      response.body.cancel(@body.BodyError::Cancelled)
      // Normal scope exit must join the cancelled upload even when its source
      // has not produced a frame or EOF.
    })
  })
  assert_eq(source_cancellations, 1)
}

///|
async test "H2 server reclaims reset, rejected, and closed-stream DATA exactly once" {
  for scenario in ["reset", "length", "window", "closed"] {
    let writer = H2LifecycleWriter::new()
    defer writer.signal.close()
    let request = security_request(Post)
    if scenario == "length" {
      request.headers.append_string("content-length", "3").unwrap()
    }
    let reader = @aio.MemoryReader(async fn(peer) {
      peer.write(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
      peer.write(Bytes::from_array(@http2.encode_settings_frame([], false)))
      peer.write(Bytes::from_array(@http2.encode_settings_frame([], true)))
      peer.write(
        @http2.encode_request_headers(
          @http2.HpackContext::new(),
          1,
          request,
          false,
        ).unwrap(),
      )
      peer.write(@http2.encode_data_frames(1, b"a", false).unwrap())
      if scenario == "closed" {
        peer.write(@http2.encode_rst_stream(1, Cancel).unwrap())
      }
      peer.write(
        @http2.encode_data_frames(
          1,
          if scenario == "length" {
            b"bcd"
          } else {
            b"bc"
          },
          false,
        ).unwrap(),
      )
      if scenario == "reset" {
        peer.write(@http2.encode_rst_stream(1, Cancel).unwrap())
      }
      peer.write(h2_lifecycle_ping())
      ignore(writer.wait_frame(@http2.H2_FRAME_PING, 0))
    })
    defer reader.close()
    @async.with_timeout(1000, async fn() {
      @service.serve_http2_connection(
        reader,
        writer,
        async fn(_) {
          @async.sleep(60_000)
          {
            status: 200,
            version: Http2,
            headers: @types.HeaderMap::new(),
            body: @body.EmptyBody::new(),
          }
        },
        config={
          ..@service.ServerConfig::defaults(),
          body_queue_capacity: 1,
          h2_receive_window_bytes: if scenario == "window" {
            1
          } else {
            65535
          },
        },
      )
    })
    assert_eq(
      writer.connection_credit(),
      if scenario == "length" {
        4
      } else {
        3
      },
    )
  }
}

///|
async test "H2 client refunds rejected and reset response DATA without double credit" {
  for rejected in [true, false] {
    let writer = H2LifecycleWriter::new()
    defer writer.signal.close()
    let processed : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
    let done : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
    defer done.close()
    let reader = @aio.MemoryReader(async fn(peer) {
      ignore(writer.wait_frame(@http2.H2_FRAME_HEADERS, 1))
      peer.write(Bytes::from_array(@http2.encode_settings_frame([], false)))
      if rejected {
        peer.write(@http2.encode_data_frames(1, b"abc", false).unwrap())
      } else {
        peer.write(security_h2_response_head(200, None, false))
        peer.write(@http2.encode_data_frames(1, b"a", false).unwrap())
        peer.write(@http2.encode_data_frames(1, b"bc", false).unwrap())
        peer.write(@http2.encode_rst_stream(1, Cancel).unwrap())
      }
      peer.write(h2_lifecycle_ping())
      ignore(writer.wait_frame(@http2.H2_FRAME_PING, 0))
      processed.put(())
      done.get()
    })
    defer reader.close()
    @async.with_timeout(1000, async fn() {
      @service.with_h2_client_connection(
        reader,
        writer,
        async fn(client) {
          try {
            let response = client.send(security_request(Get))
            processed.get()
            // fail() retains queued DATA. Draining it after reset must not refund twice.
            ignore(@body.collect(response.body))
          } catch {
            @http2.H2ProtocolError::StreamError(_, _, _) => ()
            error => raise error
          } noraise {
            _ => fail("expected the response stream to fail")
          }
          if rejected {
            processed.get()
          }
          assert_eq(writer.connection_credit(), 3)
          done.put(())
        },
        config={
          ..@service.H2ClientConfig::defaults(),
          body_queue_capacity: 1,
        },
      )
    })
  }
}

///|
async test "H2 upload completion preserves blocked terminal response DATA and trailers" {
  for with_trailers in [false, true] {
    let writer = H2LifecycleWriter::new()
    defer writer.signal.close()
    let upload = @body.BodyStream::new().unwrap()
    let response_ended : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
    let upload_ended : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
    let done : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
    defer done.close()
    let reader = @aio.MemoryReader(async fn(peer) {
      ignore(writer.wait_frame(@http2.H2_FRAME_HEADERS, 1))
      peer.write(Bytes::from_array(@http2.encode_settings_frame([], false)))
      peer.write(security_h2_response_head(200, Some("2"), false))
      peer.write(@http2.encode_data_frames(1, b"a", false).unwrap())
      peer.write(@http2.encode_data_frames(1, b"b", !with_trailers).unwrap())
      if with_trailers {
        let trailers = @types.HeaderMap::new()
        trailers.append_string("x-end", "yes").unwrap()
        peer.write(
          @http2.encode_trailers(@http2.HpackContext::new(), 1, trailers).unwrap(),
        )
      }
      peer.write(h2_lifecycle_ping())
      ignore(writer.wait_frame(@http2.H2_FRAME_PING, 0))
      response_ended.put(())
      ignore(writer.wait_frame(@http2.H2_FRAME_DATA, 1))
      peer.write(h2_lifecycle_ping())
      ignore(writer.wait_frame(@http2.H2_FRAME_PING, 0))
      upload_ended.put(())
      done.get()
    })
    defer reader.close()
    @async.with_timeout(1000, async fn() {
      @service.with_h2_client_connection(
        reader,
        writer,
        async fn(client) {
          let response = client.send(
            security_request(Post).map_body(fn(_) { upload }),
          )
          response_ended.get()
          upload.finish()
          upload_ended.get()
          let (data, trailers) = @body.collect(response.body)
          assert_eq(data, b"ab")
          assert_eq(trailers is Some(_), with_trailers)
          done.put(())
        },
        config={
          ..@service.H2ClientConfig::defaults(),
          body_queue_capacity: 1,
        },
      )
    })
  }
}

///|
async test "H2 request trailers do not block WINDOW_UPDATE for an early response" {
  let writer = H2LifecycleWriter::new()
  defer writer.signal.close()
  let reader = @aio.MemoryReader(async fn(peer) {
    peer.write(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
    peer.write(
      Bytes::from_array(
        @http2.encode_settings_frame([{ id: 4, value: 0, }], false),
      ),
    )
    let encoder = @http2.HpackContext::new()
    peer.write(
      @http2.encode_request_headers(encoder, 1, security_request(Post), false).unwrap(),
    )
    peer.write(@http2.encode_data_frames(1, b"a", false).unwrap())
    peer.write(@http2.encode_data_frames(1, b"b", false).unwrap())
    peer.write(
      @http2.encode_trailers(encoder, 1, @types.HeaderMap::new()).unwrap(),
    )
    peer.write(@http2.encode_window_update(1, 1).unwrap())
    let response = writer.wait_frame(@http2.H2_FRAME_DATA, 1)
    assert_eq(Bytes::from_array(response.payload), b"x")
    ignore(writer.wait_frame(@http2.H2_FRAME_DATA, 1))
  })
  defer reader.close()
  @async.with_timeout(1000, async fn() {
    @service.serve_http2_connection(
      reader,
      writer,
      fn(_) {
        {
          status: 200,
          version: Http2,
          headers: @types.HeaderMap::new(),
          body: @body.FullBody::new(b"x"),
        }
      },
      config={ ..@service.ServerConfig::defaults(), body_queue_capacity: 1, },
    )
  })
  assert_eq(writer.connection_credit(), 2)
}
