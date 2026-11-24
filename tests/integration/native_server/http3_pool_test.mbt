///|
async test "HTTP/3 pool shares a cold origin, drains GOAWAY and bounds distinct origins on one address" {
  @async.with_timeout(10000, async fn() {
    let (ct, st) = listener_tls_options()
    let policy = @transport.AllowAllPolicy::new()
    let routes : H3TestRoutePolicy = { denied: [], lookups: [], }
    let mut connections = 0
    let mut requests = 0
    let (endpoint, listener) = bind_test_listener(endpoint => {
      @server.NativeHttp3Listener::bind(
        endpoint,
        policy,
        { ..st, alpn: ["h3"], },
        async fn(_, io) {
          connections += 1
          while true {
            for event in io.next_events() {
              if event is Message(H3HeadersReceived(id, fields, false, false)) {
                requests += 1
                if fields.any(f => f.name == ":path" && f.value == b"/drain") {
                  io.session.send_goaway(id + 4L).unwrap_or_error()
                  io.flush()
                }
                io.session
                .send_headers(id, [
                  @http3.QpackField::from_strings(":status", "200").unwrap(),
                ])
                .unwrap_or_error()
                io.session
                .send_data(id, b"accepted", fin=true)
                .unwrap_or_error()
              }
            }
          }
        },
      )
    })
    defer listener.close()
    let supervisor = @server_api.ServerSupervisor::new().unwrap()
    let resolver = @transport.StaticResolver::new([
      ("localhost", [@types.IpAddress::parse("127.0.0.1").unwrap()]),
    ])
    fn request(host : String, path : String) -> @types.Request[@body.FullBody] {
      {
        http_method: Get,
        uri: @types.Uri::parse(
          "https://" + host + ":" + endpoint.port().to_string() + path,
        ).unwrap(),
        version: Http3,
        headers: @types.HeaderMap::new(),
        body: @body.FullBody::new(b""),
      }
    }
    @async.with_task_group(async fn(group) {
      let serving = group.spawn(async fn() { listener.serve(supervisor) })
      @client_native.with_http3_pool(
        resolver,
        routes,
        async fn(pool) {
          let first = group.spawn(async fn() {
            pool.send(request("LOCALHOST", "/"))
          })
          let other = pool.send(request("localhost", "/"))
          assert_eq(@body.collect(other.body).0, b"accepted")
          let held = first.wait()
          assert_eq(connections, 1)
          assert_eq(routes.lookups, ["localhost"])
          // Both URI hosts reach the same socket and match the certificate.
          // The unread response still owns the sole connection slot.
          let numeric = group.spawn(async fn() {
            pool.send(request("127.0.0.1", "/"))
          })
          @async.pause()
          assert_true(numeric.try_wait() is None)
          assert_eq(pool.connection_count(), 1)
          assert_eq(@body.collect(held.body).0, b"accepted")
          assert_eq(@body.collect(numeric.wait().body).0, b"accepted")
          assert_eq(connections, 2)
          let draining = pool.send(request("127.0.0.1", "/drain"))
          let replacement = group.spawn(async fn() {
            pool.send(request("127.0.0.1", "/"))
          })
          @async.pause()
          assert_true(replacement.try_wait() is None)
          assert_eq(@body.collect(draining.body).0, b"accepted")
          assert_eq(@body.collect(replacement.wait().body).0, b"accepted")
          assert_eq(connections, 3)
          assert_eq(requests, 5)
        },
        tls={ ..ct, server_name: None, alpn: ["h3"], },
        max_connections=1,
      )
      supervisor.begin_shutdown().unwrap()
      assert_eq(serving.wait(), Ok(()))
      assert_eq(supervisor.metrics().completed(), 3L)
    })
  })
}
