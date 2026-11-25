///|
async fn echo_scoped_request(
  request : @types.Request[@body.BodyStream],
) -> @types.Response[@body.FullBody] {
  if request.uri.path == "/early" {
    return {
      status: 413,
      version: request.version,
      headers: @types.HeaderMap::new(),
      body: @body.FullBody::new(b"finished"),
    }
  }
  let (data, _) = @body.collect(request.body)
  {
    status: 200,
    version: request.version,
    headers: @types.HeaderMap::new(),
    body: @body.FullBody::new(data),
  }
}

///|
async fn check_scoped_client(
  version : @types.Version,
  endpoint : @types.Endpoint,
  tls : @transport.TlsOptions,
) -> Unit {
  let uri = @types.Uri::parse(
    "https://127.0.0.1:" + endpoint.port().to_string() + "/echo",
  ).unwrap()
  @client_native.with_client(
    async fn(client) {
      let get = client.send(
        client.request(Get, uri, @client_api.Upload::bytes(b"")),
      )
      assert_eq(get.version, version)
      assert_eq(@body.collect(get.body).0, b"")
      let chunks = [b"abc", b"def"]
      let source = @body.BodyStream::from_pull(
        () => chunks.pop().map(chunk => Data(chunk)),
        size_hint=@body.SizeHint::exact(6),
      )
      let post = client.send(
        client.request(Post, uri, @client_api.Upload::once(source)),
      )
      assert_eq(post.version, version)
      assert_eq(@body.collect(post.body).0, b"defabc")
      if version != Http10 {
        let mut stopped = 0
        let waiting = @body.BodyStream::from_pull(
          async fn() {
            @async.sleep(60000)
            None
          },
          on_cancel=_ => stopped += 1,
        )
        let early = client.send(
          client.request(
            Post,
            uri.resolve_reference("/early").unwrap(),
            @client_api.Upload::once(waiting),
          ),
        )
        assert_eq(early.status, 413)
        assert_eq(@body.collect(early.body).0, b"finished")
        assert_eq(stopped, 1)
        let next = client.send(
          client.request(Get, uri, @client_api.Upload::bytes(b"")),
        )
        next.body.cancel(@body.BodyError::Cancelled)
      }
    },
    version~,
    options={
      ..@client_api.RequestOptions::defaults(),
      limits: if version == Http2 {
        @types.Limits::new(max_concurrent_requests=1, max_buffer_bytes=8192).unwrap()
      } else {
        @types.Limits::defaults()
      },
    },
    policy=@transport.AllowAllPolicy::new(),
    tls={ ..tls, server_name: None, },
  )
}

///|
async test "scoped client sends GET and incremental POST over all four wire versions" {
  @async.with_timeout(15000, async fn() {
    let (client_tls, server_tls) = listener_tls_options()
    let policy = @transport.AllowAllPolicy::new()
    for version in [@types.Version::Http10, Http11, Http2, Http3] {
      let supervisor = @server_api.ServerSupervisor::new().unwrap()
      let alpn = match version {
        Http3 => ["h3"]
        Http2 => ["h2"]
        _ => ["http/1.1"]
      }
      let tls = { ..server_tls, alpn, }
      let client_options = { ..client_tls, alpn, }
      @async.with_task_group(async fn(group) {
        if version == Http3 {
          let (endpoint, listener) = bind_test_listener(endpoint => {
            @server.NativeHttp3Listener::bind_http(
              endpoint, policy, tls, echo_scoped_request,
            )
          })
          defer listener.close()
          let server = group.spawn(async fn() { listener.serve(supervisor) })
          check_scoped_client(version, endpoint, client_options)
          supervisor.begin_shutdown().unwrap()
          assert_eq(server.wait(), Ok(()))
        } else {
          let endpoint = unused_tcp_endpoint()
          let listener = @server.NativeTcpListener::bind_http_tls(
            endpoint,
            policy,
            @tls_native.NativeTlsProvider::new(),
            tls,
            echo_scoped_request,
          ).unwrap()
          defer listener.close()
          let server = group.spawn(async fn() { supervisor.serve(listener) })
          check_scoped_client(version, endpoint, client_options)
          supervisor.begin_shutdown().unwrap()
          assert_eq(server.wait(), Ok(()))
        }
      })
    }
  })
}

///|
async fn check_stalled_stream(version : @types.Version) -> Unit {
  let (client_tls, server_tls) = listener_tls_options()
  let policy = @transport.AllowAllPolicy::new()
  let supervisor = @server_api.ServerSupervisor::new().unwrap()
  let entered : @aqueue.Queue[Unit] = Queue(kind=Blocking(1))
  let handler = async fn(
    req : @types.Request[@body.BodyStream],
  ) -> @types.Response[@body.BodyStream] {
    if req.uri.path != "/" {
      entered.put(())
    }
    if req.uri.path == "/head" {
      @async.sleep(200)
    }
    if req.uri.path == "/upload" {
      ignore(@body.collect(req.body))
    }
    let slow = req.uri.path == "/body"
    let mut sent = false
    {
      status: 200,
      version: req.version,
      headers: @types.HeaderMap::new(),
      body: @body.BodyStream::from_pull(async fn() {
        if sent {
          return None
        }
        sent = true
        if slow {
          @async.sleep(200)
        }
        Some(Data(b"ok"))
      }),
    }
  }
  let tls = {
    ..server_tls,
    alpn: [if version == Http2 { "h2" } else { "h3" }],
  }
  let (endpoint, close, serve) = if version == Http2 {
    let endpoint = unused_tcp_endpoint()
    let listener = @server.NativeTcpListener::bind_http_tls(
      endpoint,
      policy,
      @tls_native.NativeTlsProvider::new(),
      tls,
      handler,
    ).unwrap()
    (
      endpoint,
      () => listener.close(),
      async fn() { supervisor.serve(listener).unwrap() },
    )
  } else {
    let (endpoint, listener) = bind_test_listener(endpoint => {
      @server.NativeHttp3Listener::bind_http(endpoint, policy, tls, handler)
    })
    (
      endpoint,
      () => listener.close(),
      async fn() { listener.serve(supervisor).unwrap_or_error() },
    )
  }
  defer close()
  let origin = @types.Uri::parse(
    "https://127.0.0.1:" + endpoint.port().to_string() + "/",
  ).unwrap()
  @async.with_task_group(async fn(group) {
    let server = group.spawn(serve)
    let options = @client_api.RequestOptions::defaults()
    for
      (path, expected) in [
        ("/head", @client_api.ClientResponseHeaders),
        ("/body", ClientResponseBody),
        ("/upload", ClientRequestBody),
      ] {
      let accepted = supervisor.metrics().accepted()
      @client_native.with_client(
        async fn(client) {
          let mut cancelled = 0
          let blocked = group.spawn(async fn() {
            let upload = if path == "/upload" {
              @client_api.Upload::once(
                @body.BodyStream::from_pull(
                  async fn() {
                    @async.sleep(2000)
                    None
                  },
                  on_cancel=_ => cancelled += 1,
                ),
              )
            } else {
              @client_api.Upload::bytes(b"")
            }
            let result = try {
              let res = client.send(
                client.request(
                  if path == "/upload" {
                    Post
                  } else {
                    Get
                  },
                  origin.resolve_reference(path).unwrap(),
                  upload,
                ),
              )
              ignore(@body.collect(res.body))
              None
            } catch {
              @client_api.ClientError::ClientTimeout(phase, _, _) => Some(phase)
              e => raise e
            }
            assert_eq(result, Some(expected))
          })
          entered.get()
          let ok = client.send(
            client.request(Get, origin, @client_api.Upload::bytes(b"")),
          )
          assert_eq(@body.collect(ok.body).0, b"ok")
          blocked.wait()
          if path == "/upload" {
            assert_eq(cancelled, 1)
          }
          let ok = client.send(
            client.request(Get, origin, @client_api.Upload::bytes(b"")),
          )
          assert_eq(@body.collect(ok.body).0, b"ok")
          assert_eq(supervisor.metrics().accepted(), accepted + 1L)
        },
        version~,
        policy~,
        max_connections=1,
        tls={ ..client_tls, alpn: tls.alpn, server_name: None, },
        options={
          ..options,
          timeouts: {
            ..options.timeouts,
            request_body_ms: if expected == ClientRequestBody {
              Some(20)
            } else {
              None
            },
            response_headers_ms: if expected == ClientResponseHeaders {
              Some(40)
            } else {
              None
            },
            response_body_ms: if expected == ClientResponseBody {
              Some(40)
            } else {
              None
            },
            total_ms: Some(4000),
          },
        },
      )
    }
    supervisor.begin_shutdown().unwrap()
    server.wait()
  })
}

///|
async test "a stalled H2 stream times out independently of its peer" {
  check_stalled_stream(Http2)
}

///|
async test "a stalled H3 stream times out independently of its peer" {
  check_stalled_stream(Http3)
}

///|
async test "H3 request headers cover local admission and an unlimited stage resumes" {
  let (client_tls, server_tls) = listener_tls_options()
  let policy = @transport.AllowAllPolicy::new()
  let seen : Array[String] = []
  let (endpoint, listener) = bind_test_listener(endpoint => {
    @server.NativeHttp3Listener::bind_http(
      endpoint,
      policy,
      { ..server_tls, alpn: ["h3"], },
      req => {
        seen.push(req.uri.path)
        {
          status: 200,
          version: Http3,
          headers: @types.HeaderMap::new(),
          body: @body.FullBody::new(b"ok"),
        }
      },
    )
  })
  defer listener.close()
  let origin = @types.Uri::parse("https://127.0.0.1:\{endpoint.port()}/first").unwrap()
  let supervisor = @server_api.ServerSupervisor::new().unwrap()
  @async.with_task_group(async fn(group) {
    let server = group.spawn(async fn() {
      listener.serve(supervisor).unwrap_or_error()
    })
    let defaults = @client_api.RequestOptions::defaults()
    for
      (header_ms, total_ms, expected) in [
        (Some(40), Some(3000), Some(@client_api.ClientRequestHeaders)),
        (None, Some(3000), None),
      ] {
      seen.clear()
      @client_native.with_client(
        async fn(client) {
          let first = client.send(
            client.request(Get, origin, @client_api.Upload::bytes(b"")),
          )
          let mut cancelled = 0
          let mut started = false
          let second = group.spawn(async fn() {
            started = true
            let upload = @body.BodyStream::from_pull(() => None, on_cancel=_ => {
              cancelled += 1
            })
            try {
              let res = client.send(
                client.request(
                  Get,
                  origin.resolve_reference("/second").unwrap(),
                  @client_api.Upload::once(upload),
                ),
              )
              ignore(@body.collect(res.body))
              None
            } catch {
              @client_api.ClientError::ClientTimeout(phase, _, _) => Some(phase)
              error => raise error
            }
          })
          while !started {
            @async.pause()
          }
          if expected is None {
            assert_eq(seen, ["/first"])
            ignore(@body.collect(first.body))
          }
          assert_eq(second.wait(), expected)
          if expected is Some(_) {
            assert_eq(seen, ["/first"])
            assert_eq(cancelled, 1)
            ignore(@body.collect(first.body))
          }
          let third = client.send(
            client.request(
              Get,
              origin.resolve_reference("/third").unwrap(),
              @client_api.Upload::bytes(b""),
            ),
          )
          assert_eq(@body.collect(third.body).0, b"ok")
        },
        version=Http3,
        policy~,
        max_connections=1,
        tls={ ..client_tls, alpn: ["h3"], server_name: None, },
        options={
          ..defaults,
          limits: @types.Limits::new(max_concurrent_requests=1).unwrap(),
          timeouts: {
            ..defaults.timeouts,
            request_headers_ms: header_ms,
            total_ms,
          },
        },
      )
    }
    assert_eq(supervisor.metrics().accepted(), 2L)
    supervisor.begin_shutdown().unwrap()
    server.wait()
  })
}

///|
async test "H3 HEADERS blocked by peer credit consume the header budget" {
  let (client_tls, server_tls) = listener_tls_options()
  let policy = @transport.AllowAllPolicy::new()
  let mut calls = 0
  let (peer, listener) = bind_test_listener(endpoint => {
    @server.NativeHttp3Listener::bind_http(
      endpoint,
      policy,
      { ..server_tls, alpn: ["h3"], },
      req => {
        calls += 1
        {
          status: 200,
          version: req.version,
          headers: @types.HeaderMap::new(),
          body: @body.FullBody::new(b""),
        }
      },
      transport_params={
        ..@quic.QuicTransportParams::defaults(),
        initial_max_stream_data_bidi_remote: 0L,
      },
    )
  })
  defer listener.close()
  let uri = @types.Uri::parse("https://127.0.0.1:\{peer.port()}/").unwrap()
  let supervisor = @server_api.ServerSupervisor::new().unwrap()
  @async.with_task_group(async fn(group) {
    let server = group.spawn(async fn() {
      listener.serve(supervisor).unwrap_or_error()
    })
    let options = @client_api.RequestOptions::defaults()
    for
      (headers_ms, total_ms, expected) in [
        (40, 3000, @client_api.ClientRequestHeaders),
        (5000, 300, ClientTotal),
      ] {
      @client_native.with_client(
        async fn(client) {
          let mut cancelled = 0
          let upload = @body.BodyStream::from_pull(
            () => fail("upload polled before HEADERS"),
            on_cancel=_ => cancelled += 1,
          )
          try
            client.send(
              client.request(Post, uri, @client_api.Upload::once(upload)),
            )
          catch {
            @client_api.ClientError::ClientTimeout(phase, _, _) =>
              assert_eq(phase, expected)
            error => raise error
          } noraise {
            _ => fail("blocked HEADERS returned a response")
          }
          assert_eq(cancelled, 1)
        },
        version=Http3,
        policy~,
        tls={ ..client_tls, alpn: ["h3"], server_name: None, },
        options={
          ..options,
          timeouts: {
            ..options.timeouts,
            request_headers_ms: Some(headers_ms),
            total_ms: Some(total_ms),
          },
        },
      )
    }
    assert_eq(calls, 0)
    supervisor.begin_shutdown().unwrap()
    server.wait()
  })
}

///|
async test "Native H1 H2 H3 handlers distinguish two client certificates from one CA" {
  @async.with_timeout(15000, async fn() {
    let (client_tls, server_tls) = listener_tls_options()
    let roots = @fs.read_binary("tests/fixtures/tls/chain_root.cert.pem")
    let policy = @transport.AllowAllPolicy::new()
    for version in [@types.Version::Http11, Http2, Http3] {
      let alpn = match version {
        Http3 => ["h3"]
        Http2 => ["h2"]
        _ => ["http/1.1"]
      }
      let server_options = {
        ..server_tls,
        verify_peer: true,
        trust_anchors: Some(roots),
        alpn,
      }
      let observed : Array[@transport.VerifiedClientCertificate] = []
      async fn handler(
        context : @server.RequestContext,
        request : @types.Request[@body.BodyStream],
      ) -> @types.Response[@body.FullBody] {
        observed.push(context.verified_client_certificate.unwrap())
        @body.collect(request.body) |> ignore
        {
          status: 200,
          version: request.version,
          headers: @types.HeaderMap::new(),
          body: @body.FullBody::new(b"ok"),
        }
      }
      async fn exercise(endpoint : @types.Endpoint) -> Unit {
        let uri = @types.Uri::parse(
          "https://127.0.0.1:" + endpoint.port().to_string() + "/",
        ).unwrap()
        for
          (name, key) in [
            ("workload-a", "client_only"),
            ("workload-b", "other"),
          ] {
          let options = {
            ..client_tls,
            server_name: None,
            alpn,
            client_certificate: Some(
              @fs.read_binary("tests/fixtures/tls/" + name + ".cert.pem"),
            ),
            client_private_key: Some(
              @fs.read_binary("tests/fixtures/tls/" + key + ".key.pem"),
            ),
          }
          @client_native.with_client(
            async fn(client) {
              let request = client.request(
                Get,
                uri,
                @client_api.Upload::bytes(b""),
              )
              request.headers
              .append_string("x-client-certificate", "untrusted-input")
              .unwrap()
              let response = client.send(request)
              assert_eq(@body.collect(response.body).0, b"ok")
            },
            version~,
            policy~,
            tls=options,
          )
        }
        assert_eq(observed.length(), 2)
        assert_true(observed[0].sha256 != observed[1].sha256)
        for index, leaf in observed {
          assert_eq(leaf.sha256.length(), 32)
          assert_eq(leaf.subject_alt_names.length(), 1)
          assert_eq(
            leaf.subject_alt_names[0],
            UriName(
              if index == 0 {
                "spiffe://test/workload-a"
              } else {
                "spiffe://test/workload-b"
              },
            ),
          )
        }
      }
      let supervisor = @server_api.ServerSupervisor::new().unwrap()
      @async.with_task_group(async fn(group) {
        if version == Http3 {
          let (endpoint, listener) = bind_test_listener(endpoint => {
            @server.NativeHttp3Listener::bind_http_with_context(
              endpoint, policy, server_options, handler,
            )
          })
          defer listener.close()
          let serving = group.spawn(async fn() { listener.serve(supervisor) })
          exercise(endpoint)
          supervisor.begin_shutdown().unwrap()
          assert_eq(serving.wait(), Ok(()))
        } else {
          let endpoint = unused_tcp_endpoint()
          let listener = @server.NativeTcpListener::bind_http_tls_with_context(
            endpoint,
            policy,
            @tls_native.NativeTlsProvider::new(),
            server_options,
            handler,
          ).unwrap()
          defer listener.close()
          let serving = group.spawn(async fn() { supervisor.serve(listener) })
          exercise(endpoint)
          supervisor.begin_shutdown().unwrap()
          assert_eq(serving.wait(), Ok(()))
        }
      })
    }
  })
}
