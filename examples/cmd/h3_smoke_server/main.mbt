///|
/// Bounded loopback interoperability server. All wire/state logic belongs to
/// the library drivers; this executable only binds capabilities and echoes.
struct SmokeConnection {
  tls : @quic.QuicTlsDriver[@tls_native.NativeQuicTlsProvider]
  provider : @tls_native.NativeQuicTlsProvider
  h3 : @http3.Http3Session
  post_bodies : Map[Int64, Array[Byte]]
  mut last_received_ms : Int64
}

///|
fn[T, E : Error] checked(result : Result[T, E]) -> T raise E {
  match result {
    Ok(value) => value
    Err(error) => raise error
  }
}

///|
fn SmokeConnection::advance(
  self : SmokeConnection,
  actions : Array[@quic.QuicDriverAction],
  now_ms : Int64,
  output : Array[@quic.QuicDriverAction],
) -> Unit raise {
  let mut pending = self.h3.advance(actions, now_ms)
  while !pending.is_empty() {
    let mut wrote = false
    for action in pending {
      match action {
        Message(H3HeadersReceived(id, fields, false, false)) => {
          if !self.h3.can_write(id) {
            continue
          }
          if fields.any(f => f.name == ":method" && f.value == b"HEAD") {
            checked(
              self.h3.send_headers(
                id,
                [@http3.QpackField::from_strings(":status", "200").unwrap()],
                fin=true,
              ),
            )
            wrote = true
          } else if fields.any(f => f.name == ":method" && f.value == b"POST") {
            self.post_bodies[id] = []
          }
        }
        Message(H3DataReceived(id, bytes)) =>
          if self.post_bodies.get(id) is Some(body) {
            if bytes.length() > 65536 - body.length() {
              self.post_bodies.remove(id)
              checked(self.h3.cancel(id))
              wrote = true
              continue
            }
            for byte in bytes {
              body.push(byte)
            }
          }
        Message(H3MessageFinished(id)) => {
          let body = match self.post_bodies.get(id) {
            Some(bytes) => Bytes::from_array(bytes)
            None => b"MoonbitHTTP HTTP/3 smoke\n"
          }
          self.post_bodies.remove(id)
          if !self.h3.can_write(id) {
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
          checked(self.h3.send_headers(id, fields))
          checked(self.h3.send_data(id, body, fin=true))
          wrote = true
        }
        Transport(StreamReset(id, _)) => {
          self.post_bodies.remove(id)
          if self.h3.can_write(id) {
            checked(self.h3.cancel(id))
            wrote = true
          }
        }
        Transport(SendStopped(id, _)) | StreamFailed(id, _) =>
          self.post_bodies.remove(id)
        Transport(packet) => output.push(packet)
        Failed(error) => println("h3 session: \{Repr(error)}")
        _ => ()
      }
    }
    if !wrote {
      break
    }
    pending = self.h3.advance([], now_ms)
  }
}

///|
async fn main {
  let policy = @transport.AllowAllPolicy::new()
  let clock = @transport_native.NativeClock::new()
  let endpoint = @types.Endpoint::new("udp", "127.0.0.1", 18443).unwrap()
  let socket = @transport_native.UdpServerSocket::bind(endpoint, policy).unwrap()
  defer socket.close()
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
  let connections : Map[String, SmokeConnection] = Map([])
  defer (for _, connection in connections {
    connection.provider.close()
  })
  @stdio.stdout.write("HTTP/3 smoke listening on https://localhost:18443\n")
  @async.with_task_group(async fn(group) {
    // Keep the receive operation alive while the timer drives recovery. The
    // UDP adapter maps cancellation to an error, so cancelling a receive on
    // every tick would also cancel normal socket progress.
    group.spawn_bg(
      async fn() {
        while true {
          @async.sleep(25)
          let now_ms = clock.monotonic_millis()
          let expired : Array[String] = []
          let output : Array[@quic.QuicDriverAction] = []
          for key, connection in connections {
            let driver = connection.tls.datagram_driver()
            if connection.h3.ended() ||
              driver.state() == Closed ||
              driver.state() == Draining ||
              now_ms - connection.last_received_ms >= 30000L {
              expired.push(key)
            } else {
              connection.advance(
                checked(connection.tls.poll(now_ms)),
                now_ms,
                output,
              ) catch {
                error => {
                  println("h3 timer \{key}: \{error}")
                  expired.push(key)
                }
              }
            }
          }
          for key in expired {
            if connections.get(key) is Some(connection) {
              connection.provider.close()
              connections.remove(key)
            }
          }
          for action in output {
            if action is SendDatagram(destination, bytes) {
              checked(socket.send(destination, bytes))
            }
          }
        }
      },
      no_wait=true,
    )
    while true {
      let datagram = checked(socket.receive(65527))
      let source = datagram.endpoint()
      let key = source.authority()
      let payload = datagram.payload()
      let now_ms = clock.monotonic_millis()
      let connection = match connections.get(key) {
        Some(value) => value
        None => {
          if connections.length() >= 16 {
            continue
          }
          if payload.length() < 1200 {
            continue
          }
          let (version, initial_destination, peer_id, kind, _, _) = match
            @quic.quic_long_header_fields(payload) {
            Ok(value) => value
            Err(_) => continue
          }
          if version != 1 ||
            kind != 0 ||
            initial_destination.bytes().length() < 8 {
            continue
          }
          let id = @quic.ConnectionId::new(b"mbt-h3-1").unwrap()
          let driver = match
            @quic.QuicDatagramDriver::new(
              Server,
              source,
              initial_destination,
              id,
              peer_id,
              now_ms~,
              // Keep the peer's initial request allowance small so the rolling
              // interoperability case must receive fresh MAX_STREAMS credit.
              transport_params={
                ..@quic.QuicTransportParams::defaults(),
                initial_max_streams_bidi: 8L,
                initial_max_data: 1024L,
                initial_max_stream_data_bidi_remote: 256L,
              },
              authorize=fn(endpoint, operation) {
                policy.authorize(endpoint, operation)
              },
            ) {
            Ok(value) => value
            Err(_) => continue
          }
          let provider = @tls_native.NativeQuicTlsProvider::new(server=true)
          let tls = match @quic.QuicTlsDriver::new(driver, provider) {
            Ok(value) => value
            Err(_) => {
              provider.close()
              continue
            }
          }
          match tls.start(options, now_ms) {
            Ok(_) => ()
            Err(_) => {
              provider.close()
              continue
            }
          }
          let connection = {
            tls,
            provider,
            h3: checked(@http3.Http3Session::new(tls)),
            post_bodies: Map([]),
            last_received_ms: now_ms,
          }
          connections.set(key, connection)
          connection
        }
      }
      connection.last_received_ms = now_ms
      try {
        let output = []
        connection.advance(
          checked(connection.tls.on_datagram(source, payload, now_ms)),
          now_ms,
          output,
        )
        for action in output {
          if action is SendDatagram(destination, bytes) {
            checked(socket.send(destination, bytes))
          }
        }
      } catch {
        error => println("h3 connection \{key}: \{error}")
      }
    }
  })
}
