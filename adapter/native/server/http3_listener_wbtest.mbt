///|
async fn unused_udp_endpoint() -> @types.Endpoint {
  let socket = @socket.UdpServer(@socket.Addr::new(0x7f000001U, 0))
  defer socket.close()
  @types.Endpoint::new("udp", "127.0.0.1", socket.addr.port()).unwrap()
}

///|
async test "HTTP/3 listener: draining continues to route concurrent peers and final response bytes" {
  @async.with_timeout(10000, async fn() {
    let endpoint = unused_udp_endpoint()
    let (client_tls, server_tls) = listener_tls_options()
    let policy = @transport.AllowAllPolicy::new()
    let entered : @aqueue.Queue[Unit] = Queue(kind=Blocking(2))
    let release : @aqueue.Queue[Unit] = Queue(kind=Blocking(2))
    let payload = Bytes::from_array(FixedArray::make(8192, b'x'))
    let listener = NativeHttp3Listener::bind(
      endpoint,
      policy,
      { ..server_tls, alpn: ["h3"], },
      async fn(_, io) {
        while true {
          for event in io.next_events() {
            if event is Message(H3MessageFinished(id)) {
              entered.put(())
              release.get()
              h3_listener_value(
                io.session.send_headers(id, [
                  @http3.QpackField::from_strings(":status", "200").unwrap(),
                ]),
              )
              h3_listener_value(io.session.send_data(id, payload, fin=true))
              return
            }
          }
        }
      },
    ).unwrap()
    defer listener.close()
    let supervisor = @server_api.ServerSupervisor::new().unwrap()
    async fn request() -> Unit {
      @client_native.with_http3_connection(
        endpoint,
        policy,
        { ..client_tls, alpn: ["h3"], },
        async fn(io) {
          let fields = [
            (":method", "GET"),
            (":scheme", "https"),
            (":authority", endpoint.authority()),
            (":path", "/"),
          ].map(pair => @http3.QpackField::from_strings(pair.0, pair.1).unwrap())
          let id = h3_listener_value(io.session.start_request(fields, fin=true))
          let body = []
          while true {
            for event in io.next_events() {
              match event {
                Message(H3DataReceived(stream, chunk)) if stream == id =>
                  body.append(chunk.to_array())
                Message(H3MessageFinished(stream)) if stream == id => {
                  assert_eq(Bytes::from_array(body), payload)
                  @async.sleep(75)
                  return
                }
                _ => ()
              }
            }
          }
        },
      )
    }
    @async.with_task_group(async fn(group) {
      let serving = group.spawn(async fn() { listener.serve(supervisor) })
      let first = group.spawn(request)
      let second = group.spawn(request)
      entered.get()
      entered.get()
      assert_eq(supervisor.active_connections(), 2)
      supervisor.begin_shutdown().unwrap()
      release.put(())
      release.put(())
      first.wait()
      second.wait()
      assert_eq(serving.wait(), Ok(()))
    })
    assert_eq(supervisor.metrics().completed(), 2L)
    assert_eq(supervisor.metrics().handler_errors(), 0L)
    assert_eq(listener.routes.length(), 0)
    assert_eq(listener.initials.length(), 0)
  })
}

///|
async test "HTTP/3 admissions distinguish connection IDs on one address and cap pending datagrams" {
  let endpoint = unused_udp_endpoint()
  let (_, options) = listener_tls_options()
  let listener = NativeHttp3Listener::bind(
    endpoint,
    @transport.AllowAllPolicy::new(),
    { ..options, alpn: ["h3"], },
    (_, _) => (),
    pending_datagrams_per_peer=1,
  ).unwrap()
  defer listener.close()
  let source = @types.Endpoint::new("udp", "127.0.0.1", 4321).unwrap()
  fn initial(id : Bytes) -> @transport.Datagram {
    let dst = @quic.ConnectionId::new(id).unwrap()
    let src = @quic.ConnectionId::new(b"client-id").unwrap()
    let key = @quic.quic_initial_packet_key(dst, Client).unwrap()
    let opts = @quic.QuicInitialPacketOptions::defaults(dst, src, 0L)
    @transport.Datagram::new(
      @quic.quic_build_initial_packet(key, opts, b"hello").unwrap(),
      source,
    )
  }
  let a = initial(b"first-destination")
  let b = initial(b"second-destination")
  listener.route(a)
  let accepted_a = listener.admissions.pending.get()
  listener.route(a)
  listener.route(b)
  let accepted_b = listener.admissions.pending.get()
  assert_eq(listener.initials.length(), 2)
  assert_eq(listener.routes.length(), 0)
  let inbox = listener.initials[(source, b"first-destination")].inbox
  assert_eq(inbox.try_get(), Some(a))
  assert_eq(inbox.try_get(), None)
  (accepted_a.close)()
  assert_eq(listener.initials.length(), 1)
  listener.close()
  listener.route(a)
  assert_eq(listener.initials.length(), 1)
  (accepted_b.close)()
  assert_eq(listener.initials.length(), 0)
}

///|
async test "HTTP/3 typed handler: stalled upload and cancelled handler leave a streaming echo and its trailers intact" {
  @async.with_timeout(12000, async fn() {
    let endpoint = unused_udp_endpoint()
    let (client_tls, server_tls) = listener_tls_options()
    let policy = @transport.AllowAllPolicy::new()
    let entered : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
    let cancelled : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
    let stalled : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
    let mut verified = false
    let errors : Array[Int64] = []
    let listener = NativeHttp3Listener::bind_http(
      endpoint,
      policy,
      { ..server_tls, alpn: ["h3"], },
      async fn(request) {
        if request.uri.path == "/stall" {
          defer ignore(cancelled.try_put(()))
          entered.put(())
          stalled.get()
        }
        if request.uri.path == "/fail" {
          fail("application failure for one request")
        }
        if request.version == Http3 &&
          request.http_method == Post &&
          request.uri.path == "/echo" &&
          request.headers.get_string("host").map(v => v.to_string_lossy()) ==
          Some(endpoint.authority()) &&
          request.headers.get_string("x-bytes").map(v => v.bytes) ==
          Some(b"\xff") {
          verified = true
        }
        {
          status: 200,
          version: Http3,
          headers: @types.HeaderMap::new(),
          body: request.body,
        }
      },
      on_request_error=(id, _) => errors.push(id),
      transport_params={
        ..@quic.QuicTransportParams::defaults(),
        initial_max_stream_data_bidi_remote: 256L,
        initial_max_data: 8192L,
      },
    ).unwrap()
    defer listener.close()
    let supervisor = @server_api.ServerSupervisor::new().unwrap()
    @async.with_task_group(async fn(group) {
      let serving = group.spawn(async fn() { listener.serve(supervisor) })
      @client_native.with_http3_connection(
        endpoint,
        policy,
        { ..client_tls, alpn: ["h3"], },
        async fn(io) {
          fn fields(path : String) -> Array[@http3.QpackField] {
            let head = [
              (":method", "POST"),
              (":scheme", "https"),
              (":authority", endpoint.authority()),
              (":path", path),
            ].map(p => @http3.QpackField::from_strings(p.0, p.1).unwrap())
            head.push(@http3.QpackField::new("x-bytes", b"\xff").unwrap())
            head
          }
          let payload = Bytes::from_array(
            FixedArray::makei(4096, i => (i % 251).to_byte()),
          )
          let idle = h3_listener_value(
            io.session.start_request(fields("/stall")),
          )
          h3_listener_value(io.session.send_data(idle, payload))
          io.flush()
          entered.get()
          let bad = h3_listener_value(
            io.session.start_request(fields("/fail"), fin=true),
          )
          let stream = h3_listener_value(
            io.session.start_request(fields("/echo")),
          )
          h3_listener_value(io.session.send_data(stream, payload))
          let trailers = [
            @http3.QpackField::from_strings("x-check", "done").unwrap(),
          ]
          h3_listener_value(io.session.send_headers(stream, trailers, fin=true))
          let received = []
          let mut status = false
          let mut trailer = false
          let mut ended = false
          let mut failed = false
          while !ended || !failed {
            for event in io.next_events() {
              match event {
                Message(H3HeadersReceived(id, head, false, false)) if id ==
                  stream =>
                  status = head.any(f => {
                    f.name == ":status" && f.value == b"200"
                  })
                Message(H3DataReceived(id, bytes)) if id == stream =>
                  received.append(bytes.to_array())
                Message(H3HeadersReceived(id, head, true, _)) if id == stream =>
                  trailer = head == trailers
                Message(H3MessageFinished(id)) if id == stream => ended = true
                Transport(StreamReset(id, _) | SendStopped(id, _))
                | StreamFailed(id, _) if id == bad => failed = true
                _ => ()
              }
            }
          }
          assert_true(status && trailer && verified)
          assert_eq(errors, [bad])
          assert_eq(Bytes::from_array(received), payload)
          h3_listener_value(io.session.cancel(idle))
          io.flush()
          cancelled.get()
          let last = h3_listener_value(
            io.session.start_request(fields("/echo"), fin=true),
          )
          while true {
            if io.next_events().any(e => e == Message(H3MessageFinished(last))) {
              break
            }
          }
        },
      )
      supervisor.begin_shutdown().unwrap()
      assert_eq(serving.wait(), Ok(()))
    })
    assert_eq(supervisor.metrics().handler_errors(), 0L)
  })
}

///|
async test "HTTP/3 typed client: cancel a duplex response and reuse one stream slot for byte-exact trailers" {
  @async.with_timeout(10000, async fn() {
    let endpoint = unused_udp_endpoint()
    let (client_tls, server_tls) = listener_tls_options()
    let policy = @transport.AllowAllPolicy::new()
    let hold : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
    let mut upload_cancelled = 0
    let mut calls = 0
    let mut clean = false

    let listener = NativeHttp3Listener::bind_http(
      endpoint,
      policy,
      { ..server_tls, alpn: ["h3"], },
      request => {
        calls += 1
        clean = request.headers.get_string("proxy-authorization") is None
        if request.uri.path == "/early" {
          return {
            status: 413,
            version: Http3,
            headers: @types.HeaderMap::new(),
            body: @body.BodyStream::from_pull(() => None),
          }
        }
        {
          status: 200,
          version: Http3,
          headers: @types.HeaderMap::new(),
          body: request.body,
        }
      },
      transport_params={
        ..@quic.QuicTransportParams::defaults(),
        initial_max_streams_bidi: 1L,
      },
    ).unwrap()
    defer listener.close()
    let failures : Array[String] = []
    let supervisor = @server_api.ServerSupervisor::new(
      config=@server_api.ServerConfig::defaults().with_error_responder(err => {
        match err {
          @http3.Http3Error::Http3ConnectionError(code, detail) =>
            failures.push("\{code.wire_value()}: \{detail}")
          @quic.QuicError::ConnectionClosed(code, detail) =>
            failures.push("peer close \{code} \{detail}")
          _ => failures.push(err.to_string())
        }
      }),
    ).unwrap()
    @async.with_task_group(async fn(group) {
      let serving = group.spawn(async fn() { listener.serve(supervisor) })
      @client_native.with_http3_client(
        endpoint,
        policy,
        { ..client_tls, alpn: ["h3"], },
        async fn(client) {
          let waiting = @body.BodyStream::from_pull(
            async fn() {
              hold.get()
              None
            },
            on_cancel=fn(_) { upload_cancelled += 1 },
          )
          let headers = @types.HeaderMap::new()
          headers
          .append_string("proxy-authorization", "private proxy credential")
          .unwrap()
          let target = @types.Uri::parse("/duplex").unwrap()
          let first = client.send({
            http_method: Post,
            uri: target,
            version: Http3,
            headers,
            body: waiting,
          })
          assert_eq(first.status, 200)
          first.body.cancel(@body.BodyError::Cancelled)
          let stopped : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
          let early_body = @body.BodyStream::from_pull(
            async fn() {
              hold.get()
              None
            },
            on_cancel=fn(_) { ignore(stopped.try_put(()) catch { _ => false }) },
          )
          let early = client.send({
            http_method: Post,
            uri: @types.Uri::parse("/early").unwrap(),
            version: Http3,
            headers,
            body: early_body,
          })
          assert_eq(early.status, 413)
          let (empty, _) = @body.collect(early.body)
          assert_true(empty.is_empty())
          stopped.get()
          let trailers = @types.HeaderMap::new()
          trailers.append_string("x-proof", "received").unwrap()
          let payload = Bytes::from_array(
            FixedArray::makei(32768, i => (i % 239).to_byte()),
          )
          let next = client.send({
            http_method: Post,
            uri: target,
            version: Http3,
            headers,
            body: @body.QueueBody::new([Data(payload), Trailers(trailers)]),
          })
          let (received, tail) = @body.collect(next.body, max_bytes=32768)
          assert_eq(received, payload)
          assert_eq(
            tail.unwrap().get_string("x-proof").unwrap().bytes,
            b"received",
          )
          assert_eq(upload_cancelled, 1)
          assert_true(clean)
          assert_eq(calls, 3)
        },
      ) catch {
        @quic.QuicError::ConnectionClosed(code, detail) =>
          fail(
            "unexpected client close \{code} (\{detail}), listener errors \{Repr(failures)}",
          )
        err => raise err
      }
      supervisor.begin_shutdown().unwrap()
      assert_eq(serving.wait(), Ok(()))
      assert_eq(failures, [])
      assert_eq(supervisor.metrics().completed(), 1L)
    })
  })
}

///|
async test "HTTP/3 typed client: a complete response survives peer close during an unfinished upload" {
  @async.with_timeout(8000, async fn() {
    let endpoint = unused_udp_endpoint()
    let (ct, st) = listener_tls_options()
    let policy = @transport.AllowAllPolicy::new()
    let data = b"delivered before close"
    let listener = NativeHttp3Listener::bind(
      endpoint,
      policy,
      { ..st, alpn: ["h3"], },
      async fn(_, io) {
        while true {
          for action in io.next_events() {
            if action is Message(H3HeadersReceived(id, _, false, false)) {
              h3_listener_value(
                io.session.send_headers(id, [
                  @http3.QpackField::from_strings(":status", "413").unwrap(),
                ]),
              )
              h3_listener_value(io.session.send_data(id, data, fin=true))
              return
            }
          }
        }
      },
    ).unwrap()
    defer listener.close()
    let supervisor = @server_api.ServerSupervisor::new().unwrap()
    @async.with_task_group(async fn(group) {
      let serving = group.spawn(async fn() { listener.serve(supervisor) })
      @client_native.with_http3_client(
        endpoint,
        policy,
        { ..ct, alpn: ["h3"], },
        async fn(client) {
          let waiting : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
          let stopped : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
          let upload = @body.BodyStream::from_pull(
            async fn() {
              waiting.get()
              None
            },
            on_cancel=fn(_) { ignore(stopped.try_put(()) catch { _ => false }) },
          )
          let response = client.send({
            http_method: Post,
            uri: @types.Uri::parse("/").unwrap(),
            version: Http3,
            headers: @types.HeaderMap::new(),
            body: upload,
          })
          stopped.get()
          let (body, _) = @body.collect(response.body)
          assert_eq(response.status, 413)
          assert_eq(body, data)
        },
      )
      supervisor.begin_shutdown().unwrap()
      assert_eq(serving.wait(), Ok(()))
    })
  })
}

///|
async test "HTTP/3 supervisor sends each peer its GOAWAY boundary and drains a live response" {
  @async.with_timeout(8000, async fn() {
    let endpoint = unused_udp_endpoint()
    let (ct, st) = listener_tls_options()
    let tls = { ..ct, alpn: ["h3"], }
    let policy = @transport.AllowAllPolicy::new()
    let idle_ready : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
    let entered : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
    let release : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
    let mut handled = 0
    let payload = Bytes::from_array(FixedArray::make(32768, b'k'))
    let listener = NativeHttp3Listener::bind_http(
      endpoint,
      policy,
      { ..st, alpn: ["h3"], },
      async fn(_) {
        handled += 1
        entered.put(())
        release.get()
        {
          status: 200,
          version: Http3,
          headers: @types.HeaderMap::new(),
          body: @body.FullBody::new(payload),
        }
      },
      transport_params={
        ..@quic.QuicTransportParams::defaults(),
        initial_max_streams_bidi: 1L,
      },
    ).unwrap()
    defer listener.close()
    let supervisor = @server_api.ServerSupervisor::new().unwrap()
    @async.with_task_group(async fn(group) {
      let serving = group.spawn(async fn() { listener.serve(supervisor) })
      let idle = group.spawn(async fn() {
        @client_native.with_http3_connection(endpoint, policy, tls, async fn(
          io,
        ) {
          idle_ready.put(())
          let mut goaway = false
          while true {
            let events = io.next_events() catch {
              @quic.QuicError::ConnectionClosed(0x100L, _) => break
              error => raise error
            }
            if events.contains(Message(H3GoawayReceived(0L))) {
              goaway = true
            }
          }
          assert_true(goaway)
        })
      })
      @client_native.with_http3_client(endpoint, policy, tls, async fn(client) {
        fn request() -> @types.Request[@body.FullBody] {
          {
            http_method: Get,
            uri: @types.Uri::parse("/").unwrap(),
            version: Http3,
            headers: @types.HeaderMap::new(),
            body: @body.FullBody::new(b""),
          }
        }
        @async.with_task_group(async fn(requests) {
          let first = requests.spawn(async fn() { client.send(request()) })
          entered.get()
          idle_ready.get()
          let waiting = requests.spawn(async fn() {
            ignore(client.send(request())) catch {
              @service.H3ClientError::Goaway(first) => return first
              error => raise error
            }
            fail("request admitted after shutdown")
          })
          supervisor.begin_shutdown().unwrap()
          supervisor.begin_shutdown().unwrap()
          assert_eq(waiting.wait(), 4L)
          idle.wait()
          assert_eq(handled, 1)
          release.put(())
          let response = first.wait()
          let (bytes, _) = @body.collect(
            response.body,
            max_bytes=payload.length(),
          )
          assert_eq(response.status, 200)
          assert_eq(bytes, payload)
          assert_eq(serving.wait(), Ok(()))
          try ignore(client.send(request())) catch {
            @service.H3ClientError::Goaway(4L) => ()
            error => raise error
          } noraise {
            _ => fail("closed peer admitted another request")
          }
        })
      })
      assert_eq(supervisor.metrics().completed(), 2L)
      assert_eq(supervisor.metrics().handler_errors(), 0L)
      assert_eq(listener.routes.length(), 0)
    })
  })
}

///|
async test "HTTP/3 shutdown deadline joins a suspended handler and releases its UDP route" {
  @async.with_timeout(8000, async fn() {
    let endpoint = unused_udp_endpoint()
    let (ct, st) = listener_tls_options()
    let policy = @transport.AllowAllPolicy::new()
    let entered : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
    let suspended = @async.CondVar::Cond()
    let mut cleaned = 0
    let listener = NativeHttp3Listener::bind_http(
      endpoint,
      policy,
      { ..st, alpn: ["h3"], },
      async fn(request) {
        defer {
          cleaned += 1
        }
        entered.put(())
        suspended.wait()
        {
          status: 200,
          version: Http3,
          headers: @types.HeaderMap::new(),
          body: request.body,
        }
      },
    ).unwrap()
    defer listener.close()
    let supervisor = @server_api.ServerSupervisor::new(
      config=@server_api.ServerConfig::defaults().with_limits({
        ..@server_api.ServerLimits::defaults(),
        graceful_timeout_ms: Some(300),
      }),
    ).unwrap()
    @async.with_task_group(async fn(group) {
      let serving = group.spawn(async fn() { listener.serve(supervisor) })
      @client_native.with_http3_connection(
        endpoint,
        policy,
        { ..ct, alpn: ["h3"], },
        async fn(io) {
          let fields = [
            (":method", "GET"),
            (":scheme", "https"),
            (":authority", "localhost"),
            (":path", "/"),
          ].map(p => @http3.QpackField::from_strings(p.0, p.1).unwrap())
          h3_listener_value(io.session.start_request(fields, fin=true))
          |> ignore
          io.flush()
          entered.get()
          supervisor.begin_shutdown().unwrap()
          while !io.next_events().contains(Message(H3GoawayReceived(4L))) {
            continue
          }
          while true {
            ignore(io.next_events())
          }
        },
      ) catch {
        @quic.QuicError::ConnectionClosed(0x102L, _) => ()
        error => raise error
      }
      assert_eq(serving.wait(), Err(ShutdownTimeout))
      assert_eq(cleaned, 1)
      assert_eq(supervisor.active_connections(), 0)
      assert_true(listener.routes.is_empty() && listener.initials.is_empty())
    })
  })
}
