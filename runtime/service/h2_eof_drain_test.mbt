///|
fn eof_drain_input(upgrade : Bool) -> Bytes {
  let preface = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" +
    Bytes::from_array(@http2.encode_settings_frame([], false))
  if upgrade {
    b"GET / HTTP/1.1\r\nHost: example.test\r\nConnection: Upgrade, HTTP2-Settings\r\nUpgrade: h2c\r\nHTTP2-Settings: AAQAAP__\r\n\r\n" +
    preface
  } else {
    preface +
    @http2.encode_request_headers(
      @http2.HpackContext::new(),
      1,
      security_request(Get),
      true,
    ).unwrap()
  }
}

///|
test "H2 EOF drain deadline is finite and validated" {
  let defaults = @service.ServerConfig::defaults()
  assert_eq(defaults.h2_eof_drain_timeout_ms, 30000)
  for timeout in [0, -1] {
    let config = { ..defaults, h2_eof_drain_timeout_ms: timeout, }
    assert_eq(config.validate(), Err(InvalidTimeout("h2 EOF drain", timeout)))
  }
}

///|
async test "h2c EOF before initial SETTINGS cancels the outer upgrade task" {
  for partial in [b"", b"\x00\x00\x00\x04"] {
    for pending in [true, false] {
      let started : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
      let complete = eof_drain_input(true)
      let reader = @aio.MemoryReader(async fn(peer) {
        peer.write(complete[:complete.length() - 9])
        peer.write(partial)
        started.get()
      })
      defer reader.close()
      let outgoing = LifecycleFrames::new([Data(b"response")])
      let mut cleaned = 0
      let closed : Array[Error?] = []
      try
        @async.with_timeout(1000, async fn() {
          @service.serve_http1_or_h2c_connection(
            reader,
            CaptureWriter::{ bytes: [], },
            async fn(_) {
              defer {
                cleaned += 1
              }
              started.put(())
              if pending {
                @async.sleep(60_000)
              }
              lifecycle_response(outgoing)
            },
            config={
              ..@service.ServerConfig::defaults(),
              h2_eof_drain_timeout_ms: 25,
              close_callback: Some(fn(error) { closed.push(error) }),
            },
          )
        })
      catch {
        @http2.H2ProtocolError::ConnectionError(
          ProtocolError,
          "HTTP/2 peer closed before initial SETTINGS"
        ) => ()
        error => fail("incomplete upgrade failed unexpectedly: \{error}")
      } noraise {
        _ => fail("incomplete upgrade succeeded")
      }
      assert_eq(cleaned, 1)
      assert_true(closed is [Some(_)])
      if !pending {
        assert_eq(outgoing.cancelled.length(), 1)
      }
    }
  }
}

///|
async test "H2 and h2c EOF cancel suspended handlers and join cleanup" {
  for upgrade in [false, true] {
    let started : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
    let reader = @aio.MemoryReader(async fn(peer) {
      peer.write(eof_drain_input(upgrade))
      started.get()
    })
    defer reader.close()
    let mut cleaned = 0
    let closed : Array[Error?] = []
    let config = {
      ..@service.ServerConfig::defaults(),
      read_timeout_ms: None,
      write_timeout_ms: None,
      h2_eof_drain_timeout_ms: 25,
      close_callback: Some(fn(error) { closed.push(error) }),
    }
    let service : async (@types.Request[@body.BodyStream]) -> @types.Response[
      @body.EmptyBody,
    ] = async fn(_) {
      defer @async.protect_from_cancel(async fn() {
        @async.sleep(1)
        cleaned += 1
      })
      started.put(())
      @async.sleep(60_000)
      {
        status: 200,
        version: Http2,
        headers: @types.HeaderMap::new(),
        body: @body.EmptyBody::new(),
      }
    }
    try
      @async.with_timeout(1000, async fn() {
        let writer : CaptureWriter = { bytes: [], }
        if upgrade {
          @service.serve_http1_or_h2c_connection(
            reader,
            writer,
            service,
            config~,
          )
        } else {
          @service.serve_http2_connection(reader, writer, service, config~)
        }
      })
    catch {
      @http2.H2ProtocolError::ConnectionError(
        Cancel,
        "HTTP/2 peer EOF drain deadline exceeded"
      ) => ()
      error => fail("EOF drain failed with unexpected error: \{error}")
    } noraise {
      _ => fail("suspended handler completed without deadline")
    }
    assert_eq(cleaned, 1)
    assert_true(closed is [Some(_)])
  }
}

///|
async test "H2 EOF deadline cancels a suspended response body exactly once" {
  let polled : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
  let mut cancellations = 0
  let outgoing = @body.BodyStream::from_pull(
    async fn() {
      polled.put(())
      @async.sleep(60_000)
      None
    },
    on_cancel=fn(_) { cancellations += 1 },
  )
  let reader = @aio.MemoryReader(async fn(peer) {
    peer.write(eof_drain_input(false))
    polled.get()
  })
  defer reader.close()
  try
    @async.with_timeout(1000, async fn() {
      @service.serve_http2_connection(
        reader,
        CaptureWriter::{ bytes: [], },
        fn(_) {
          {
            status: 200,
            version: Http2,
            headers: @types.HeaderMap::new(),
            body: outgoing,
          }
        },
        config={
          ..@service.ServerConfig::defaults(),
          h2_eof_drain_timeout_ms: 25,
        },
      )
    })
  catch {
    @http2.H2ProtocolError::ConnectionError(
      Cancel,
      "HTTP/2 peer EOF drain deadline exceeded"
    ) => ()
    error => fail("response EOF drain failed: \{error}")
  } noraise {
    _ => fail("suspended response completed without deadline")
  }
  assert_eq(cancellations, 1)
}

///|
async test "H2 EOF grace starts at EOF and preserves finite delayed responses" {
  let reader = @aio.MemoryReader(async fn(peer) {
    // An open connection may live longer than the post-EOF deadline.
    @async.sleep(100)
    peer.write(eof_drain_input(false))
  })
  defer reader.close()
  let writer : CaptureWriter = { bytes: [], }
  let closed : Array[Error?] = []
  @async.with_timeout(1000, async fn() {
    @service.serve_http2_connection(
      reader,
      writer,
      async fn(_) {
        @async.sleep(5)
        {
          status: 200,
          version: Http2,
          headers: @types.HeaderMap::new(),
          body: @body.FullBody::new(b"finished after EOF"),
        }
      },
      config={
        ..@service.ServerConfig::defaults(),
        h2_eof_drain_timeout_ms: 50,
        close_callback: Some(fn(error) { closed.push(error) }),
      },
    )
  })
  assert_eq(closed.length(), 1)
  assert_true(closed[0] is None)
  let decoder = @http2.FrameDecoder::new()
  decoder.feed(Bytes::from_array(writer.bytes)).unwrap()
  let bytes : Array[Byte] = []
  let mut ended = false
  while decoder.next().unwrap() is Some(frame) {
    if frame.header.typ == @http2.H2_FRAME_DATA {
      bytes.append(frame.payload)
      ended = ended || (frame.header.flags & @http2.H2_FLAGS_END_STREAM) != 0
    }
  }
  assert_eq(Bytes::from_array(bytes), b"finished after EOF")
  assert_true(ended)
}

///|
async test "H2 EOF deadline covers a writer with IO timeout disabled" {
  let writer : H2GatedWriter = {
    control: H2LifecycleWriter::new(),
    started: Queue(kind=Blocking(1)),
    release: Queue(kind=Blocking(1)),
    typ: @http2.H2_FRAME_DATA,
    stream_id: 1,
    held: false,
  }
  defer writer.control.signal.close()
  let outgoing = LifecycleFrames::new([Data(b"payload")])
  let reader = @aio.MemoryReader(async fn(peer) {
    peer.write(eof_drain_input(false))
    writer.started.get()
  })
  defer reader.close()
  try
    @async.with_timeout(1000, async fn() {
      @service.serve_http2_connection(
        reader,
        writer,
        fn(_) { lifecycle_response(outgoing) },
        config={
          ..@service.ServerConfig::defaults(),
          write_timeout_ms: None,
          h2_eof_drain_timeout_ms: 25,
        },
      )
    })
  catch {
    @http2.H2ProtocolError::ConnectionError(
      Cancel,
      "HTTP/2 peer EOF drain deadline exceeded"
    ) => ()
    error => fail("writer EOF drain failed: \{error}")
  } noraise {
    _ => fail("suspended writer completed without deadline")
  }
  assert_eq(outgoing.cancelled.length(), 1)
}

///|
async test "H2 external cancellation joins handlers before EOF grace expires" {
  let started : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
  let reader = @aio.MemoryReader(async fn(peer) {
    peer.write(eof_drain_input(false))
  })
  defer reader.close()
  let mut cleaned = 0
  let closed : Array[Error?] = []
  @async.with_timeout(1000, async fn() {
    @async.with_task_group(async fn(group) {
      let connection = group.spawn(async fn() {
        @service.serve_http2_connection(
          reader,
          CaptureWriter::{ bytes: [], },
          async fn(_) {
            defer {
              cleaned += 1
            }
            started.put(())
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
            close_callback: Some(fn(error) { closed.push(error) }),
          },
        )
      })
      started.get()
      @async.pause()
      connection.cancel()
      try connection.wait() catch {
        @async.WaitedTaskAlreadyCancelled => ()
        error => fail("external cancellation changed: \{error}")
      } noraise {
        _ => fail("cancelled connection completed normally")
      }
    })
  })
  assert_eq(cleaned, 1)
  assert_true(closed is [Some(_)])
}
