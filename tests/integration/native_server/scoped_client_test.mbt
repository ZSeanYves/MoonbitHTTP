///|
async fn echo_scoped_request(
  request : @types.Request[@body.BodyStream],
) -> @types.Response[@body.FullBody] {
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
    },
    version~,
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
