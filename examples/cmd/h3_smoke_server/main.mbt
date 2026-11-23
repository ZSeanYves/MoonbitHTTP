///|
fn[T, E : Error] checked(result : Result[T, E]) -> T raise E {
  match result {
    Ok(value) => value
    Err(error) => raise error
  }
}

///|
async fn echo(_peer : @types.Endpoint, io : @service.H3ConnectionIo) -> Unit {
  let post_bodies : Map[Int64, Array[Byte]] = Map([])
  while true {
    for action in io.next_events() {
      match action {
        Message(H3HeadersReceived(id, fields, false, false)) => {
          if !io.session.can_write(id) {
            continue
          }
          if fields.any(f => f.name == ":method" && f.value == b"HEAD") {
            checked(
              io.session.send_headers(
                id,
                [@http3.QpackField::from_strings(":status", "200").unwrap()],
                fin=true,
              ),
            )
          } else if fields.any(f => f.name == ":method" && f.value == b"POST") {
            post_bodies[id] = []
          }
        }
        Message(H3DataReceived(id, bytes)) =>
          if post_bodies.get(id) is Some(body) {
            if bytes.length() > 65536 - body.length() {
              post_bodies.remove(id)
              checked(io.session.cancel(id))

              continue
            }
            body.append(bytes.to_array())
          }
        Message(H3MessageFinished(id)) => {
          let body = match post_bodies.get(id) {
            Some(bytes) => Bytes::from_array(bytes)
            None => b"MoonbitHTTP HTTP/3 smoke\n"
          }
          post_bodies.remove(id)
          if !io.session.can_write(id) {
            continue
          }
          let fields = [
            @http3.QpackField::from_strings(":status", "200").unwrap(),
            @http3.QpackField::from_strings("content-type", "text/plain").unwrap(),
            @http3.QpackField::from_strings(
              "content-length",
              body.length().to_string(),
            ).unwrap(),
          ]
          checked(io.session.send_headers(id, fields))
          checked(io.session.send_data(id, body, fin=true))
        }
        Transport(StreamReset(id, _)) => {
          post_bodies.remove(id)
          if io.session.can_write(id) {
            checked(io.session.cancel(id))
          }
        }
        Transport(SendStopped(id, _)) | StreamFailed(id, _) =>
          post_bodies.remove(id)
        _ => ()
      }
    }
  }
}

///|
async fn main {
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
  let listener = checked(
    @server_native.NativeHttp3Listener::bind(
      endpoint,
      @transport.AllowAllPolicy::new(),
      options,
      echo,
      transport_params={
        ..@quic.QuicTransportParams::defaults(),
        initial_max_streams_bidi: 8L,
        initial_max_data: 1024L,
        initial_max_stream_data_bidi_remote: 256L,
      },
    ),
  )
  defer listener.close()
  let config = @server_api.ServerConfig::defaults()
    .with_limits({
      ..@server_api.ServerLimits::defaults(),
      max_connections: 16,
    })
    .with_error_responder(error => println("HTTP/3 peer: \{error}"))
  let supervisor = checked(@server_api.ServerSupervisor::new(config~))
  @stdio.stdout.write("HTTP/3 smoke listening on https://localhost:18443\n")
  checked(listener.serve(supervisor))
}
