///|
async fn bind_test_listener(
  bind : async (@types.Endpoint) -> Result[
    @server.NativeHttp3Listener,
    @server_api.ServerError,
  ],
) -> (@types.Endpoint, @server.NativeHttp3Listener) {
  // Acquire the candidate port with the listener that will serve the test.
  // No temporary socket is closed between selecting the port and using it.
  let bytes = FixedArray::make(2, b'\x00')
  for attempt = 0; ; attempt = attempt + 1 {
    @tls_native.NativeEntropy::new().fill(bytes).unwrap_or_error()
    let port = 49152 + (((bytes[0].to_int() << 8) | bytes[1].to_int()) & 16383)
    let endpoint = @types.Endpoint::new("udp", "127.0.0.1", port).unwrap()
    match bind(endpoint) {
      Ok(listener) => return (endpoint, listener)
      Err(AcceptFailed(_)) if attempt < 7 => continue
      Err(error) => raise error
    }
  }
}

///|
async test "HTTP/3 typed handler: stalled upload and cancelled handler leave a streaming echo and its trailers intact" {
  @async.with_timeout(12000, async fn() {
    let (client_tls, server_tls) = listener_tls_options()
    let policy = @transport.AllowAllPolicy::new()
    let entered : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
    let cancelled : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
    let stalled : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
    let mut verified = false
    let errors : Array[Int64] = []
    let (endpoint, listener) = bind_test_listener(endpoint => {
      @server.NativeHttp3Listener::bind_http(
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
      )
    })
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
          let idle = io.session
            .start_request(fields("/stall"))
            .unwrap_or_error()
          io.session.send_data(idle, payload).unwrap_or_error()
          io.flush()
          entered.get()
          let bad = io.session
            .start_request(fields("/fail"), fin=true)
            .unwrap_or_error()
          let upload = fields("/echo")
          upload.push(
            @http3.QpackField::from_strings("expect", "100-continue").unwrap(),
          )
          let stream = io.session.start_request(upload).unwrap_or_error()
          let mut continued = false
          let trailers = [
            @http3.QpackField::from_strings("x-check", "done").unwrap(),
          ]

          let received = []
          let mut status = false
          let mut trailer = false
          let mut ended = false
          let mut failed = false
          while !ended || !failed {
            for event in io.next_events() {
              match event {
                Message(H3HeadersReceived(id, head, false, true)) if id ==
                  stream => {
                  assert_false(continued)
                  assert_true(
                    head.any(f => f.name == ":status" && f.value == b"100"),
                  )
                  continued = true
                  io.session.send_data(stream, payload).unwrap_or_error()
                  io.session
                  .send_headers(stream, trailers, fin=true)
                  .unwrap_or_error()
                }
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
          assert_true(continued && status && trailer && verified)
          assert_eq(errors, [bad])
          assert_eq(Bytes::from_array(received), payload)
          io.session.cancel(idle).unwrap_or_error()
          io.flush()
          cancelled.get()
          let rejected_head = fields("/fail")
          rejected_head.push(
            @http3.QpackField::from_strings("expect", "custom").unwrap(),
          )
          let rejected = io.session
            .start_request(rejected_head)
            .unwrap_or_error()
          let mut rejected_status = false
          let mut rejected_end = false
          while !rejected_end {
            for event in io.next_events() {
              match event {
                Message(H3HeadersReceived(id, head, false, false)) if id ==
                  rejected =>
                  rejected_status = head.any(f => {
                    f.name == ":status" && f.value == b"417"
                  })
                Message(H3MessageFinished(id)) if id == rejected =>
                  rejected_end = true
                _ => ()
              }
            }
          }
          assert_true(rejected_status)
          assert_eq(errors, [bad])
          let last = io.session
            .start_request(fields("/echo"), fin=true)
            .unwrap_or_error()
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
    let (client_tls, server_tls) = listener_tls_options()
    let policy = @transport.AllowAllPolicy::new()
    let hold : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
    let mut upload_cancelled = 0
    let mut calls = 0
    let mut clean = false

    let (endpoint, listener) = bind_test_listener(endpoint => {
      @server.NativeHttp3Listener::bind_http(
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
      )
    })
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
      @client_native.with_http3_client_connection(
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
          let expect = @types.HeaderMap::new()
          expect.append_string("expect", "100-continue").unwrap()
          try
            ignore(
              client.send({
                http_method: Post,
                uri: target,
                version: Http3,
                headers: expect,
                body: @body.EmptyBody::new(),
              }),
            )
          catch {
            @service.Http3ClientError::InvalidRequest(_) => ()
            error => raise error
          } noraise {
            _ => fail("accepted a known-empty upload with 100-continue")
          }
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
struct H3TestRoutePolicy {
  denied : Array[String]
  lookups : Array[String]
}

///|
impl @transport.NetworkPolicy for H3TestRoutePolicy with fn authorize(
  self,
  endpoint,
  operation,
) {
  match operation {
    Resolve => self.lookups.push(endpoint.host())
    QuicEndpoint if endpoint.host() == "127.0.0.2" => {
      self.denied.push(endpoint.host())
      return Err(Denied(operation, "blocked test address"))
    }
    _ => ()
  }
  Ok(())
}

///|
async test "HTTP/3 typed client: a complete response survives peer close during an unfinished upload" {
  @async.with_timeout(8000, async fn() {
    let (ct, st) = listener_tls_options()
    let policy = @transport.AllowAllPolicy::new()
    let data = b"delivered before close"
    let (endpoint, listener) = bind_test_listener(endpoint => {
      @server.NativeHttp3Listener::bind(
        endpoint,
        policy,
        { ..st, alpn: ["h3"], },
        async fn(_, io) {
          while true {
            for action in io.next_events() {
              if action is Message(H3HeadersReceived(id, _, false, false)) {
                io.session
                .send_headers(id, [
                  @http3.QpackField::from_strings(":status", "413").unwrap(),
                ])
                .unwrap_or_error()
                io.session.send_data(id, data, fin=true).unwrap_or_error()
                return
              }
            }
          }
        },
      )
    })
    defer listener.close()
    let supervisor = @server_api.ServerSupervisor::new().unwrap()
    @async.with_task_group(async fn(group) {
      let serving = group.spawn(async fn() { listener.serve(supervisor) })
      let routes : H3TestRoutePolicy = { denied: [], lookups: [], }
      let destination = @types.Endpoint::new(
        "udp",
        "route.test",
        endpoint.port(),
      ).unwrap()
      let resolver = @transport.StaticResolver::new([
        (
          "route.test",
          [
            @types.IpAddress::parse("127.0.0.2").unwrap(),
            @types.IpAddress::parse("127.0.0.1").unwrap(),
            @types.IpAddress::parse("224.0.0.2").unwrap(),
          ],
        ),
      ])
      @client_native.with_http3_client_connection(
        destination,
        routes,
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
        resolver=Some(resolver),
      )
      // A transport-shaped error from the application must propagate once.
      let mut callbacks = 0
      try
        @client_native.with_http3_client_connection(
          destination,
          routes,
          { ..ct, alpn: ["h3"], },
          fn(_) -> Unit raise {
            callbacks += 1
            raise @transport.TransportError::Failed(
              Receive,
              "application finished",
            )
          },
          resolver=Some(resolver),
        )
      catch {
        @transport.TransportError::Failed(Receive, "application finished") => ()
        other => raise other
      } noraise {
        _ => fail("application error was lost")
      }
      assert_eq(callbacks, 1)
      assert_eq(routes.lookups, ["route.test", "route.test"])
      assert_eq(routes.denied, ["127.0.0.2", "127.0.0.2"])
      supervisor.begin_shutdown().unwrap()
      assert_eq(serving.wait(), Ok(()))
    })
  })
}
