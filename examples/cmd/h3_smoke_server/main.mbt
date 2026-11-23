///|
fn echo(
  request : @types.Request[@body.BodyStream],
) -> @types.Response[@body.BodyStream] raise {
  let headers = @types.HeaderMap::new()
  headers.append_string("content-type", "text/plain").unwrap_or_error()
  let body = if request.http_method == Post {
    if request.headers.get_string("content-length") is Some(length) {
      headers.append(
        @types.HeaderName::parse("content-length").unwrap(),
        length,
      )
    }
    request.body
  } else {
    let bytes = b"MoonbitHTTP HTTP/3 smoke\n"
    headers
    .append_string("content-length", bytes.length().to_string())
    .unwrap_or_error()
    let full = @body.FullBody::new(bytes)
    @body.BodyStream::from_pull(() => @body.Body::next_frame(full))
  }
  { status: 200, version: Http3, headers, body, }
}

///|
async fn main {
  let once = match @env.args() {
    [_] => false
    [_, "--once"] => true
    _ => fail("usage: h3_smoke_server [--once]")
  }
  let endpoint = @types.Endpoint::new("udp", "127.0.0.1", 18443).unwrap()
  let certificate = @fs.read_file(
    "adapter/native/tls/testdata/localhost.cert.pem",
  ).binary()
  let private_key = @fs.read_file(
    "adapter/native/tls/testdata/localhost.key.pem",
  ).binary()
  let options = {
    ..@transport.TlsOptions::defaults(),
    verify_peer: false,
    alpn: ["h3"],
    server_certificate: Some(certificate),
    server_private_key: Some(private_key),
  }
  let config = @server_api.ServerConfig::defaults()
    .with_limits({
      ..@server_api.ServerLimits::defaults(),
      max_connections: 16,
    })
    .with_error_responder(error => println("HTTP/3 peer: \{error}"))
  let supervisor = @server_api.ServerSupervisor::new(config~).unwrap_or_error()
  let listener = @server_native.NativeHttp3Listener::bind(
    endpoint,
    @transport.AllowAllPolicy::new(),
    options,
    (_, io) => {
      @service.serve_http3_connection(io, async fn(request) {
        if request.http_method == Post {
          io.rotate_local_connection_id()
        }
        if once {
          supervisor.begin_shutdown().unwrap_or_error()
        }
        echo(request)
      })
    },
    limits={ ..@types.Limits::defaults(), max_body_bytes: 65536, },
    transport_params={
      ..@quic.QuicTransportParams::defaults(),
      initial_max_streams_bidi: 8L,
      initial_max_data: 1024L,
      initial_max_stream_data_bidi_remote: 256L,
    },
  ).unwrap_or_error()
  defer listener.close()
  @stdio.stdout.write("HTTP/3 smoke listening on https://localhost:18443\n")
  listener.serve(supervisor).unwrap_or_error()
}
