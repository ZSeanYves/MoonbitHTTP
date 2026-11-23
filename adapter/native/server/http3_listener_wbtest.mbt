///|
async test "HTTP/3 listener: draining continues to route concurrent peers and final response bytes" {
  @async.with_timeout(10000, async fn() {
    let reservation = @socket.UdpServer(@socket.Addr::new(0x7f000001U, 0))
    let endpoint = @types.Endpoint::new(
      "udp",
      "127.0.0.1",
      reservation.addr.port(),
    ).unwrap()
    reservation.close()
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
  let reservation = @socket.UdpServer(@socket.Addr::new(0x7f000001U, 0))
  let endpoint = @types.Endpoint::new(
    "udp",
    "127.0.0.1",
    reservation.addr.port(),
  ).unwrap()
  reservation.close()
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
