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
async test "a stalled H2 stream times out independently of its peer" {
  let (client_tls, server_tls) = listener_tls_options()
  let endpoint = unused_tcp_endpoint()
  let policy = @transport.AllowAllPolicy::new()
  let supervisor = @server_api.ServerSupervisor::new().unwrap()
  let listener = @server.NativeTcpListener::bind_http_tls(
    endpoint,
    policy,
    @tls_native.NativeTlsProvider::new(),
    { ..server_tls, alpn: ["h2"], },
    async fn(req) {
      if req.uri.path == "/head" {
        @async.sleep(600)
      }
      if req.uri.path == "/upload" {
        ignore(@body.collect(req.body))
      }
      let slow = req.uri.path == "/body"
      let mut sent = false
      {
        status: 200,
        version: Http2,
        headers: @types.HeaderMap::new(),
        body: @body.BodyStream::from_pull(async fn() {
          if sent {
            return None
          }
          sent = true
          if slow {
            @async.sleep(600)
          }
          Some(Data(b"ok"))
        }),
      }
    },
  ).unwrap()
  defer listener.close()
  let origin = @types.Uri::parse(
    "https://127.0.0.1:" + endpoint.port().to_string() + "/",
  ).unwrap()
  @async.with_task_group(async fn(group) {
    let server = group.spawn(() => supervisor.serve(listener))
    let options = @client_api.RequestOptions::defaults()
    @client_native.with_client(
      async fn(client) {
        for
          (path, expected) in [
            ("/head", @client_api.ClientResponseHeaders),
            ("/body", ClientResponseBody),
            ("/upload", ClientRequestBody),
          ] {
          let blocked = group.spawn(async fn() {
            let upload = if path == "/upload" {
              @client_api.Upload::once(
                @body.BodyStream::from_pull(async fn() {
                  @async.sleep(2000)
                  None
                }),
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
          let ok = client.send(
            client.request(Get, origin, @client_api.Upload::bytes(b"")),
          )
          assert_eq(@body.collect(ok.body).0, b"ok")
          blocked.wait()
        }
        let ok = client.send(
          client.request(Get, origin, @client_api.Upload::bytes(b"")),
        )
        assert_eq(@body.collect(ok.body).0, b"ok")
        assert_eq(supervisor.metrics().accepted(), 1L)
      },
      version=Http2,
      policy~,
      max_connections=1,
      tls={ ..client_tls, alpn: ["h2"], server_name: None, },
      options={
        ..options,
        timeouts: {
          ..options.timeouts,
          request_body_ms: Some(100),
          response_headers_ms: Some(350),
          response_body_ms: Some(150),
          total_ms: Some(4000),
        },
      },
    )
    supervisor.begin_shutdown().unwrap()
    server.wait().unwrap()
  })
}
