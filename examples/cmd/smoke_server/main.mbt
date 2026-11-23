///|
async fn[B : @body.Body] serve_cleartext(
  port : Int,
  handler : async (@types.Request[@body.BodyStream]) -> @types.Response[B],
) -> Unit {
  let server = @socket.TcpServer(
    @socket.Addr::parse("127.0.0.1:" + port.to_string()),
    reuse_addr=true,
  )
  server.run_forever(async fn(connection, _address) {
    @service.serve_auto_connection(connection, connection, handler) catch {
      error => println("connection error: \{error}")
    }
  })
}

///|
async fn buffered_echo(
  request : @types.Request[@body.BodyStream],
) -> @types.Response[@body.FullBody] {
  let (bytes, _) = @body.collect(request.body, max_bytes=1024 * 1024)
  let headers = @types.HeaderMap::new()
  headers.append_string("content-type", "application/octet-stream").unwrap()
  {
    status: 200,
    version: request.version,
    headers,
    body: @body.FullBody::new(bytes),
  }
}

///|
async fn main {
  match @env.args() {
    [_] =>
      serve_cleartext(18080, async fn(request) {
        @async.pause()
        let headers = @types.HeaderMap::new()
        ignore(headers.append_string("content-type", "text/plain"))
        let body = if request.http_method == Post {
          request.body
        } else {
          let stream = @body.BodyStream::new(capacity=2).unwrap()
          stream.push(Data(b"MoonbitHTTP smoke\n"))
          stream.finish()
          stream
        }
        { status: 200, version: request.version, headers, body, }
      })
    [_, "--echo-h1", port] =>
      serve_cleartext(@string.parse_int(port), buffered_echo)
    [_, "--echo-h2", port, cert, key] => {
      let endpoint = @types.Endpoint::new(
        "tcp",
        "127.0.0.1",
        @string.parse_int(port),
      ).unwrap()
      let tls = {
        ..@transport.TlsOptions::defaults(),
        alpn: ["h2"],
        verify_peer: false,
        server_certificate: Some(@fs.read_file(cert).binary()),
        server_private_key: Some(@fs.read_file(key).binary()),
      }
      let listener = match
        @native_server.NativeTcpListener::bind_http_tls(
          endpoint,
          @transport.AllowAllPolicy::new(),
          @tls_native.NativeTlsProvider::new(),
          tls,
          buffered_echo,
        ) {
        Ok(value) => value
        Err(error) => raise error
      }
      let supervisor = @server_api.ServerSupervisor::new().unwrap()
      match supervisor.serve(listener) {
        Ok(_) => ()
        Err(error) => raise error
      }
    }
    _ => fail("usage: smoke_server [--echo-h1 PORT | --echo-h2 PORT CERT KEY]")
  }
}
