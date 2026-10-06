///|
struct LifecycleFrames {
  frames : Array[@body.Frame]
  mut cursor : Int
  cancelled : Array[Error]
  polled : @aqueue.Queue[Unit]
}

///|
fn LifecycleFrames::new(frames : Array[@body.Frame]) -> LifecycleFrames {
  { frames, cursor: 0, cancelled: [], polled: Queue(kind=Unbounded), }
}

///|
impl @body.Body for LifecycleFrames with fn next_frame(self) {
  self.polled.put(())
  if self.cursor == self.frames.length() {
    None
  } else {
    let frame = self.frames[self.cursor]
    self.cursor += 1
    Some(frame)
  }
}

///|
impl @body.Body for LifecycleFrames with fn size_hint(_self) {
  @body.SizeHint::unknown()
}

///|
impl @body.Body for LifecycleFrames with fn cancel(self, error) {
  self.cancelled.push(error)
}

///|
fn lifecycle_response(
  body : LifecycleFrames,
) -> @types.Response[LifecycleFrames] {
  { status: 200, version: Http2, headers: @types.HeaderMap::new(), body, }
}

///|
async test "security lifecycle: H2 EOF wakes existing and future send-credit waits" {
  for already_waiting in [false, true] {
    let outgoing = LifecycleFrames::new([Data(b"payload")])
    let reader = @aio.MemoryReader(async fn(peer) {
      peer.write(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
      peer.write(
        Bytes::from_array(
          @http2.encode_settings_frame([{ id: 4, value: 0, }], false),
        ),
      )
      peer.write(
        @http2.encode_request_headers(
          @http2.HpackContext::new(),
          1,
          security_request(Get),
          true,
        ).unwrap(),
      )
      if already_waiting {
        outgoing.polled.get()
      }
    })
    let writer = H2LifecycleWriter::new()
    let closed : Array[Error?] = []
    try
      @async.with_timeout(1000, async fn() {
        @service.serve_http2_connection(
          reader,
          writer,
          async fn(_) {
            if !already_waiting {
              @async.pause()
            }
            lifecycle_response(outgoing)
          },
          config={
            ..@service.ServerConfig::defaults(),
            close_callback: Some(fn(error) { closed.push(error) }),
          },
        )
      })
    catch {
      @http2.H2ProtocolError::ConnectionError(ProtocolError, _) => ()
      error => fail("unexpected EOF failure: \{error}")
    } noraise {
      _ => fail("zero-credit response survived peer EOF")
    }
    assert_eq(outgoing.cancelled.length(), 1)
    assert_eq(closed.length(), 1)
    assert_true(closed[0] is Some(_))
  }
}

///|
async test "security lifecycle: H2 reset cancels a response already waiting for credit" {
  let outgoing = LifecycleFrames::new([Data(b"payload")])
  let reader = @aio.MemoryReader(async fn(peer) {
    peer.write(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
    peer.write(
      Bytes::from_array(
        @http2.encode_settings_frame([{ id: 4, value: 0, }], false),
      ),
    )
    peer.write(
      @http2.encode_request_headers(
        @http2.HpackContext::new(),
        1,
        security_request(Get),
        true,
      ).unwrap(),
    )
    outgoing.polled.get()
    peer.write(@http2.encode_rst_stream(1, Cancel).unwrap())
  })
  let closed : Array[Error?] = []
  @async.with_timeout(1000, async fn() {
    @service.serve_http2_connection(
      reader,
      H2LifecycleWriter::new(),
      fn(_) { lifecycle_response(outgoing) },
      config={
        ..@service.ServerConfig::defaults(),
        close_callback: Some(fn(error) { closed.push(error) }),
      },
    )
  })
  assert_eq(outgoing.cancelled.length(), 1)
  assert_eq(closed.length(), 1)
}

///|
struct LifecycleFailingWriter {
  typ : Int
}

///|
impl @aio.Writer for LifecycleFailingWriter with fn write_once(
  self,
  data,
  offset~,
  len~,
) {
  let bytes = data[offset:offset + len]
  if len >= 9 &&
    bytes != b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" &&
    bytes[3].to_int() == self.typ &&
    bytes[8] == b'\x01' {
    raise Http1LifecycleFailure("frame write")
  }
  len
}

///|
async test "security lifecycle: H2 header and DATA write failures cancel owned response once" {
  for typ in [@http2.H2_FRAME_HEADERS, @http2.H2_FRAME_DATA] {
    let outgoing = LifecycleFrames::new([Data(b"payload")])
    let reader = @aio.MemoryReader(async fn(peer) {
      peer.write(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
      peer.write(Bytes::from_array(@http2.encode_settings_frame([], false)))
      peer.write(
        @http2.encode_request_headers(
          @http2.HpackContext::new(),
          1,
          security_request(Get),
          true,
        ).unwrap(),
      )
    })
    try
      @service.serve_http2_connection(
        reader,
        LifecycleFailingWriter::{ typ, },
        fn(_) { lifecycle_response(outgoing) },
      )
    catch {
      Http1LifecycleFailure("frame write") => ()
      error => fail("response failure changed: \{error}")
    } noraise {
      _ => fail("response write succeeded")
    }
    assert_eq(outgoing.cancelled.map(http1_lifecycle_error_label), [
      "frame write",
    ])
  }
}

///|
async test "security lifecycle: H2 request header failure cancels body before upload begins" {
  let outgoing = LifecycleFrames::new([Data(b"upload")])
  let reader = @aio.MemoryReader(async fn(_) { @async.sleep(60_000) })
  @async.with_timeout(1000, async fn() {
    @service.with_h2_client_connection(
      reader,
      LifecycleFailingWriter::{ typ: @http2.H2_FRAME_HEADERS, },
      async fn(client) {
        try
          client.send(security_request(Post).map_body(fn(_) { outgoing }))
        catch {
          Http1LifecycleFailure("frame write") => ()
          error => fail("request failure changed: \{error}")
        } noraise {
          _ => fail("request write succeeded")
        }
      },
    )
  })
  assert_eq(outgoing.cursor, 0)
  assert_eq(outgoing.cancelled.length(), 1)
}

///|
#warnings("-alert_internal")
struct LifecycleRequestReader {
  reader_buffer : @aio.ReaderBuffer
  chunks : Array[Bytes]
  mut cursor : Int
  pushed : @aqueue.Queue[Unit]
}

///|
#warnings("-alert_internal")
impl @aio.Reader for LifecycleRequestReader with fn _get_internal_buffer(self) {
  self.reader_buffer
}

///|
#warnings("-alert_internal")
fn LifecycleRequestReader::new(
  chunks : Array[Bytes],
  pushed : @aqueue.Queue[Unit],
) -> LifecycleRequestReader {
  { reader_buffer: @aio.ReaderBuffer::new(), chunks, cursor: 0, pushed, }
}

///|
impl @aio.Reader for LifecycleRequestReader with fn _direct_read(
  self,
  buf,
  offset~,
  max_len~,
) {
  if self.cursor == self.chunks.length() {
    return 0
  }
  let chunk = self.chunks[self.cursor]
  assert_true(chunk.length() <= max_len)
  for index in 0..<chunk.length() {
    buf[offset + index] = chunk[index]
  }
  self.cursor += 1
  if self.cursor == 3 {
    self.pushed.put(())
  }
  chunk.length()
}

///|
async test "security lifecycle: HTTP1 and h2c completion wakes an already-full request queue" {
  for upgrade in [false, true] {
    let gate : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
    let head = if upgrade {
      b"POST / HTTP/1.1\r\nHost: example.test\r\nConnection: Upgrade, HTTP2-Settings\r\nUpgrade: h2c\r\nHTTP2-Settings: AAQAAP__\r\nTransfer-Encoding: chunked\r\n\r\n"
    } else {
      b"POST / HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\n\r\n"
    }
    let ending = if upgrade {
      b"0\r\n\r\nPRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" +
      Bytes::from_array(@http2.encode_settings_frame([], false))
    } else {
      b"0\r\n\r\n"
    }
    let reader = LifecycleRequestReader::new(
      [head, b"1\r\na\r\n", b"1\r\nb\r\n", ending],
      gate,
    )
    let outgoing = LifecycleFrames::new([Data(b"ok")])
    let service = async fn(_) {
      gate.get()
      @async.pause()
      lifecycle_response(outgoing)
    }
    let closed : Array[Error?] = []
    let config = {
      ..@service.ServerConfig::defaults(),
      body_queue_capacity: 1,
      close_callback: Some(fn(error) { closed.push(error) }),
    }
    @async.with_timeout(1000, async fn() {
      if upgrade {
        @service.serve_http1_or_h2c_connection(
          reader,
          CaptureWriter::{ bytes: [], },
          service,
          config~,
        )
      } else {
        @service.serve_http1_connection(
          reader,
          CaptureWriter::{ bytes: [], },
          service,
          config~,
        )
      }
    })
    assert_eq(reader.cursor, 4)
    assert_eq(outgoing.cancelled.length(), 0)
    assert_eq(closed.length(), 1)
  }
}

///|
async test "security lifecycle: HTTP1 lazy echo consumes request beyond queue capacity" {
  let gate : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
  let reader = LifecycleRequestReader::new(
    [
      b"POST / HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\n\r\n",
      b"1\r\na\r\n", b"1\r\nb\r\n", b"1\r\nc\r\n0\r\n\r\n",
    ],
    gate,
  )
  let writer : CaptureWriter = { bytes: [], }
  @async.with_timeout(1000, async fn() {
    @service.serve_http1_connection(
      reader,
      writer,
      fn(request) {
        {
          status: 200,
          version: Http11,
          headers: @types.HeaderMap::new(),
          body: request.body,
        }
      },
      config={ ..@service.ServerConfig::defaults(), body_queue_capacity: 1, },
    )
  })
  let response = @utf8.decode_lossy(Bytes::from_array(writer.bytes))
  assert_true(response.contains("1\r\na\r\n1\r\nb\r\n1\r\nc\r\n"))
}

///|
async test "security lifecycle: h2c abandoned staged response is cancelled once" {
  for invalid_preface in [false, true] {
    let outgoing = LifecycleFrames::new([Data(b"response")])
    let created : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
    let reader = @aio.MemoryReader(async fn(peer) {
      peer.write(
        b"POST / HTTP/1.1\r\nHost: example.test\r\nConnection: Upgrade, HTTP2-Settings\r\nUpgrade: h2c\r\nHTTP2-Settings: AAQAAP__\r\nContent-Length: 4\r\n\r\n",
      )
      created.get()
      if invalid_preface {
        peer.write(b"bodyXXXXXXXXXXXXXXXXXXXXXXXX")
      }
    })
    try
      @async.with_timeout(1000, async fn() {
        @service.serve_http1_or_h2c_connection(
          reader,
          CaptureWriter::{ bytes: [], },
          async fn(_) {
            created.put(())
            lifecycle_response(outgoing)
          },
        )
      })
    catch {
      @http1.Http1Error::UnexpectedEof(_) => assert_false(invalid_preface)
      @http2.H2ProtocolError::ConnectionError(ProtocolError, _) =>
        assert_true(invalid_preface)
      error => fail("unexpected upgrade failure: \{error}")
    } noraise {
      _ => fail("aborted upgrade succeeded")
    }
    assert_eq(outgoing.cursor, 0)
    assert_eq(outgoing.cancelled.length(), 1)
  }
}
