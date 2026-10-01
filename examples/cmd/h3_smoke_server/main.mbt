///|
/// Bounded loopback interoperability server. All wire/state logic belongs to
/// the library drivers; this executable only binds capabilities and echoes.
struct SmokeConnection {
  tls : @quic.QuicTlsDriver[@tls_native.NativeQuicTlsProvider]
  provider : @tls_native.NativeQuicTlsProvider
  h3 : @http3.Http3Driver
  post_streams : Map[Int64, Bool]
  bodies : Map[Int64, Array[Byte]]
  mut initialized : Bool
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
fn SmokeConnection::send_stream(
  self : SmokeConnection,
  stream : Int64,
  bytes : Bytes,
  fin : Bool,
  now_ms : Int64,
) -> Array[@quic.QuicDriverAction] raise {
  let packets = self.tls.datagram_driver()
  let output : Array[@quic.QuicDriverAction] = []
  // Small chunks keep smoke payloads below both packet and path MTU bounds.
  let mut cursor = 0
  while cursor < bytes.length() {
    let end = (cursor + 1000).min(bytes.length())
    let frame = checked(
      packets
      .connection()
      .send_stream(
        stream,
        bytes[cursor:end].to_owned(),
        fin && end == bytes.length(),
      ),
    )
    output.push(checked(packets.send_frames(Application, [frame], now_ms)))
    cursor = end
  }
  if bytes.is_empty() && fin {
    let frame = checked(packets.connection().send_stream(stream, b"", true))
    output.push(checked(packets.send_frames(Application, [frame], now_ms)))
  }
  output
}

///|
fn SmokeConnection::h3_actions(
  self : SmokeConnection,
  actions : Array[@http3.H3DriverAction],
  now_ms : Int64,
) -> Array[@quic.QuicDriverAction] raise {
  let output : Array[@quic.QuicDriverAction] = []
  for action in actions {
    match action {
      SendOnStream(id, bytes, fin) =>
        output.append(self.send_stream(id, bytes, fin, now_ms))
      Event(H3HeadersReceived(id, fields, false, _)) => {
        self.bodies.set(id, [])
        self.post_streams.set(
          id,
          fields.any(fn(field) {
            field.name == ":method" && field.value == b"POST"
          }),
        )
      }
      Event(H3DataReceived(id, bytes)) => {
        let body = self.bodies.get_or_init(id, fn() { [] })
        if bytes.length() > 65536 - body.length() {
          fail("smoke body limit exceeded")
        }
        for byte in bytes {
          body.push(byte)
        }
      }
      ResetStream(id, code) =>
        output.push(
          checked(
            self.tls
            .datagram_driver()
            .send_frames(
              Application,
              [ResetStream(id, code.wire_value(), 0L)],
              now_ms,
            ),
          ),
        )
      CloseConnection(code) =>
        output.push(
          checked(
            self.tls
            .datagram_driver()
            .send_frames(
              Application,
              [ConnectionClose(false, code.wire_value(), 0L, b"")],
              now_ms,
            ),
          ),
        )
      _ => ()
    }
  }
  output
}

///|
fn SmokeConnection::receive(
  self : SmokeConnection,
  source : @types.Endpoint,
  payload : Bytes,
  now_ms : Int64,
) -> Array[@quic.QuicDriverAction] raise {
  let actions = match self.tls.on_datagram(source, payload, now_ms) {
    Ok(value) => value
    Err(error) => {
      println(@debug.to_string(error))
      raise error
    }
  }
  let output : Array[@quic.QuicDriverAction] = []
  if !self.initialized && self.tls.datagram_driver().state() == Established {
    for expected in [3L, 7L, 11L] {
      let id = checked(self.tls.datagram_driver().open_unidirectional_stream())
      if id != expected {
        fail("HTTP/3 critical stream allocation mismatch")
      }
    }
    output.append(
      self.h3_actions(checked(self.h3.initial_stream_actions()), now_ms),
    )
    self.initialized = true
  }
  for action in actions {
    match action {
      StreamData(id, bytes, fin) => {
        output.append(
          self.h3_actions(
            checked(self.h3.on_stream_data(id, bytes, fin)),
            now_ms,
          ),
        )
        if fin && (id & 2L) == 0L {
          let body = if self.post_streams.get(id).unwrap_or(false) {
            Bytes::from_array(self.bodies.get(id).unwrap_or([]))
          } else {
            b"MoonbitHTTP HTTP/3 smoke\n"
          }
          let fields = [
            @http3.QpackField::from_strings(":status", "200").unwrap(),
            @http3.QpackField::from_strings("content-type", "text/plain").unwrap(),
            @http3.QpackField::from_strings(
              "content-length",
              body.length().to_string(),
            ).unwrap(),
          ]
          let (headers, _) = checked(self.h3.encode_headers(id, fields))
          output.append(self.send_stream(id, headers, false, now_ms))
          let (data, _) = checked(self.h3.encode_data(body, fin=true))
          output.append(self.send_stream(id, data, true, now_ms))
          self.bodies.remove(id)
          self.post_streams.remove(id)
          println("h3 response stream=\{id} bytes=\{body.length()}")
        }
      }
      _ => output.push(action)
    }
  }
  output
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
  println("HTTP/3 smoke listening on https://localhost:18443")
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
            if driver.state() == Closed ||
              driver.state() == Draining ||
              now_ms - connection.last_received_ms >= 30000L {
              expired.push(key)
            } else {
              match connection.tls.poll(now_ms) {
                Ok(actions) => output.append(actions)
                Err(error) => {
                  println("h3 timer \{key}: \{Repr(error)}")
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
          let (_, initial_destination, peer_id, kind, _, _) = match
            @quic.quic_long_header_fields(payload) {
            Ok(value) => value
            Err(_) => continue
          }
          if kind != 0 {
            continue
          }
          let id = @quic.ConnectionId::new(b"mbt-h3-1").unwrap()
          let driver = @quic.QuicDatagramDriver::new(
            Server,
            source,
            initial_destination,
            id,
            peer_id,
            now_ms~,
            authorize=fn(endpoint, operation) {
              policy.authorize(endpoint, operation)
            },
          ).unwrap()
          let provider = @tls_native.NativeQuicTlsProvider::new(server=true)
          let tls = @quic.QuicTlsDriver::new(driver, provider).unwrap()
          ignore(tls.start(options, now_ms).unwrap())
          let connection = {
            tls,
            provider,
            h3: @http3.Http3Driver::new(H3Server).unwrap(),
            post_streams: Map([]),
            bodies: Map([]),
            initialized: false,
            last_received_ms: now_ms,
          }
          connections.set(key, connection)
          connection
        }
      }
      connection.last_received_ms = now_ms
      try {
        for action in connection.receive(source, payload, now_ms) {
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
