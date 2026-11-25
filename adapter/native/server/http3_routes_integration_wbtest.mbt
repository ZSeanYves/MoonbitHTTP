///|
async fn listener_tls_options() -> (
  @transport.TlsOptions,
  @transport.TlsOptions,
) {
  let certificate = @fs.read_binary("tests/fixtures/tls/localhost.cert.pem")
  let key = @fs.read_binary("tests/fixtures/tls/localhost.key.pem")
  (
    {
      ..@transport.TlsOptions::defaults(),
      server_name: Some("localhost"),
      trust_anchors: Some(certificate),
      alpn: ["http/1.1"],
    },
    {
      ..@transport.TlsOptions::defaults(),
      verify_peer: false,
      server_certificate: Some(certificate),
      server_private_key: Some(key),
      alpn: ["http/1.1"],
    },
  )
}

///|
fn listener_test_initial(
  source : @types.Endpoint,
  id : Bytes,
) -> @transport.Datagram {
  let dst = @quic.ConnectionId::new(id).unwrap()
  let src = @quic.ConnectionId::new(b"client-id").unwrap()
  let key = @quic.quic_initial_packet_key(dst, Client).unwrap()
  let opts = @quic.QuicInitialPacketOptions::defaults(dst, src, 0L)
  @transport.Datagram::new(
    @quic.quic_build_initial_packet(
      key,
      opts,
      @quic.quic_encode_frames([Ping]).unwrap(),
    ).unwrap(),
    source,
  )
}

///|
async test "HTTP/3 shared socket routes stateless resets among peers at one address" {
  let (_, options) = listener_tls_options()
  let (_, listener) = bind_test_listener(endpoint => {
    NativeHttp3Listener::bind(
      endpoint,
      @transport.AllowAllPolicy::new(),
      { ..options, alpn: ["h3"], },
      (_, _) => (),
      pending_datagrams_per_peer=1,
    )
  })
  defer listener.close()
  let source = @types.Endpoint::new("udp", "127.0.0.1", 4321).unwrap()
  async fn add(
    id : Bytes,
    route : Bytes,
    token : Bytes,
  ) -> (H3PeerSocket, @quic.QuicDriverAction) {
    listener.route(listener_test_initial(source, id))
    ignore(listener.admissions.pending.get())
    let peer = listener.initials[source][id]
    let remote_id = @quic.ConnectionId::new(id).unwrap()
    let local_id = @quic.ConnectionId::new(route).unwrap()
    // Seed a recipient with an authenticated test token. The routing decision
    // is identical for a token learned from an encrypted CID announcement.
    let driver = @quic.QuicDatagramDriver::new(
      Client,
      source,
      remote_id,
      local_id,
      remote_id,
    ).unwrap()
    driver
    .set_peer_transport_parameters({
      ..@quic.QuicTransportParameters::new(
        remote_id,
        original_destination_connection_id=Some(remote_id),
      ),
      stateless_reset_token: Some(token),
    })
    .unwrap()
    let action = driver.send_frames(Initial, [Ping], 0L).unwrap()
    peer.packets = Some(driver)
    assert_true(peer.reserve_route(local_id))
    (peer, action)
  }
  let route_a = Bytes::make(16, b'A')
  let token_a = Bytes::make(16, b'a')
  let token_b = Bytes::make(16, b'b')
  let token_c = Bytes::make(16, b'c')
  let (a, queued) = add(b"first peer", route_a, token_a)
  let (b, _) = add(b"second peer", Bytes::make(16, b'B'), token_b)
  let (c, _) = add(b"third peer", Bytes::make(16, b'C'), token_c)
  listener.route(@transport.Datagram::new(b"\xc0test" + token_c, source))
  assert_true(c.closed && !b.closed && !a.closed)
  listener.route(@transport.Datagram::new(b"\x40" + route_a + token_b, source))
  assert_true(b.closed && !a.closed)
  assert_eq(listener.initials[source].length(), 1)
  assert_eq(listener.routes.length(), 1)
  // The one remaining inbox still holds its Initial and cannot accept a packet.
  listener.route(@transport.Datagram::new(b"\x40" + route_a + token_a, source))
  assert_true(a.closed)
  assert_true(listener.routes.is_empty() && listener.initials.is_empty())
  let result = try {
    ignore(@transport.DatagramSocket::receive(a, 1200))
    false
  } catch {
    @quic.QuicError::ConnectionClosed(0L, "QUIC stateless reset") => true
    err => raise err
  }
  assert_true(result)
  assert_true(
    a.packets.unwrap().send_action(a, queued)
    is Err(ConnectionClosed(0L, "QUIC stateless reset")),
  )
}

///|
async fn bind_test_listener(
  bind : async (@types.Endpoint) -> Result[
    NativeHttp3Listener,
    @server_api.ServerError,
  ],
) -> (@types.Endpoint, NativeHttp3Listener) {
  // Acquire the candidate port with the listener that will serve the test.
  // No temporary socket is closed between selecting the port and using it.
  let bytes = FixedArray::make(2, b'\x00')
  for attempt = 0; ; attempt = attempt + 1 {
    @tls_native.NativeEntropy::new().fill(bytes).unwrap_or_error()
    let port = 49152 + (((bytes[0].to_int() << 8) | bytes[1].to_int()) & 16383)
    let endpoint = @types.Endpoint::new("udp", "127.0.0.1", port).unwrap()
    match bind(endpoint) {
      Ok(listener) => return (endpoint, listener)
      Err(ListenerIo(SystemFailure(Bind, _, _))) if attempt < 7 => continue
      Err(error) => raise error
    }
  }
}

///|
async test "HTTP/3 listener: rotate two peers independently while draining their final response bytes" {
  @async.with_timeout(10000, async fn() {
    let (client_tls, server_tls) = listener_tls_options()
    let policy = @transport.AllowAllPolicy::new()
    let entered : @aqueue.Queue[Unit] = Queue(kind=Blocking(2))
    let rotate : @aqueue.Queue[Unit] = Queue(kind=Blocking(2))
    let release : @aqueue.Queue[Unit] = Queue(kind=Blocking(2))
    let payload = Bytes::from_array(FixedArray::make(8192, b'x'))
    let (endpoint, listener) = bind_test_listener(endpoint => {
      NativeHttp3Listener::bind(
        endpoint,
        policy,
        { ..server_tls, alpn: ["h3"], },
        async fn(_, io) {
          while true {
            for event in io.next_events() {
              if event is Message(H3MessageFinished(id)) {
                entered.put(())
                rotate.get()
                io.rotate_local_connection_id()
                release.get()
                io.session
                .send_headers(id, [
                  @http3.QpackField::from_strings(":status", "200").unwrap(),
                ])
                .unwrap_or_error()
                io.session.send_data(id, payload, fin=true).unwrap_or_error()
                return
              }
            }
          }
        },
      )
    })
    defer listener.close()
    let supervisor = @server_api.ServerSupervisor::new().unwrap()
    async fn request() -> Unit {
      @client_native.with_http3_connection(
        endpoint,
        policy,
        { ..client_tls, alpn: ["h3"], },
        async fn(io) {
          io.rotate_local_connection_id()
          let fields = [
            (":method", "GET"),
            (":scheme", "https"),
            (":authority", endpoint.authority()),
            (":path", "/"),
          ].map(pair => @http3.QpackField::from_strings(pair.0, pair.1).unwrap())
          let id = io.session.start_request(fields, fin=true).unwrap_or_error()
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
      while listener.routes.length() != 4 {
        @async.sleep(1)
      }
      let original = listener.routes.keys().to_array()
      rotate.put(())
      rotate.put(())
      while original.filter(id => listener.routes.contains(id)).length() != 2 ||
            listener.routes.length() != 4 {
        @async.sleep(1)
      }
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
  let (_, options) = listener_tls_options()
  let (_, listener) = bind_test_listener(endpoint => {
    NativeHttp3Listener::bind(
      endpoint,
      @transport.AllowAllPolicy::new(),
      { ..options, alpn: ["h3"], },
      (_, _) => (),
      pending_datagrams_per_peer=1,
    )
  })
  defer listener.close()
  let source = @types.Endpoint::new("udp", "127.0.0.1", 4321).unwrap()
  let a = listener_test_initial(source, b"first-destination")
  let b = listener_test_initial(source, b"second-destination")
  listener.route(a)
  let accepted_a = listener.admissions.pending.get()
  listener.route(a)
  listener.route(b)
  let accepted_b = listener.admissions.pending.get()
  assert_eq(listener.initials[source].length(), 2)
  assert_eq(listener.routes.length(), 0)
  let inbox = listener.initials[source][b"first-destination"].inbox
  assert_eq(inbox.try_get(), Some(a))
  assert_eq(inbox.try_get(), None)
  (accepted_a.close)()
  assert_eq(listener.initials[source].length(), 1)
  listener.close()
  listener.route(a)
  assert_eq(listener.initials[source].length(), 1)
  (accepted_b.close)()
  assert_eq(listener.initials.length(), 0)
}

///|
async test "HTTP/3 supervisor sends each peer its GOAWAY boundary and drains a live response" {
  @async.with_timeout(8000, async fn() {
    let (ct, st) = listener_tls_options()
    let tls = { ..ct, alpn: ["h3"], }
    let policy = @transport.AllowAllPolicy::new()
    let idle_ready : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
    let entered : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
    let release : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
    let mut handled = 0
    let payload = Bytes::from_array(FixedArray::make(32768, b'k'))
    let (endpoint, listener) = bind_test_listener(endpoint => {
      NativeHttp3Listener::bind_http(
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
      )
    })
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
      @client_native.with_http3_client_connection(endpoint, policy, tls, async fn(
        client,
      ) {
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
              @service.Http3ClientError::Goaway(first) => return first
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
            @service.Http3ClientError::Goaway(4L) => ()
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
    let (ct, st) = listener_tls_options()
    let policy = @transport.AllowAllPolicy::new()
    let entered : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
    let suspended = @async.Cond::Cond()
    let mut cleaned = 0
    let (endpoint, listener) = bind_test_listener(endpoint => {
      NativeHttp3Listener::bind_http(
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
      )
    })
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
          io.session.start_request(fields, fin=true).unwrap_or_error() |> ignore
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
