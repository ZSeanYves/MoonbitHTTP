///|
/// Bounded loopback interoperability server. All wire/state logic belongs to
/// the library drivers; this executable only binds capabilities and echoes.
struct SmokeConnection {
  tls : @quic.QuicTlsDriver[@tls_native.NativeQuicTlsProvider]
  provider : @tls_native.NativeQuicTlsProvider
  h3 : @http3.Http3Driver
  post_bodies : Map[Int64, Array[Byte]]
  writes : Map[Int64, @deque.Deque[PendingWrite]]
  mut queued_bytes : Int
  mut queued_writes : Int
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
struct PendingWrite {
  bytes : Bytes
  fin : Bool
  mut offset : Int
}

///|
fn SmokeConnection::enqueue(
  self : SmokeConnection,
  stream : Int64,
  bytes : Bytes,
  fin : Bool,
) -> Unit raise {
  if self.queued_writes >= 1024 ||
    bytes.length() > 1024 * 1024 - self.queued_bytes {
    fail("smoke response queue limit exceeded")
  }
  self.writes
  .get_or_init(stream, fn() { @deque.from_array([]) })
  .push_back({ bytes, fin, offset: 0, })
  self.queued_writes += 1
  self.queued_bytes += bytes.length()
}

///|
fn SmokeConnection::flush_writes(
  self : SmokeConnection,
  output : Array[@quic.QuicDriverAction],
  now_ms : Int64,
) -> Result[Unit, @quic.QuicError] {
  let finished : Array[Int64] = []
  for id, queue in self.writes {
    guard queue.front() is Some(write) else { continue }
    match
      self.tls
      .datagram_driver()
      .send_stream_prefix(id, write.bytes[write.offset:], write.fin, now_ms) {
      Ok(Some((count, packet))) => {
        output.push(packet)
        write.offset += count
        if write.offset == write.bytes.length() {
          ignore(queue.pop_front())
          self.queued_writes -= 1
          self.queued_bytes -= write.bytes.length()
        }
      }
      Ok(None) => ()
      Err(error) => return Err(error)
    }
    if queue.is_empty() {
      finished.push(id)
    }
  }
  for id in finished {
    self.writes.remove(id)
  }
  Ok(())
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
      SendOnStream(id, bytes, fin) => self.enqueue(id, bytes, fin)
      Event(H3HeadersReceived(id, fields, false, false)) =>
        if fields.any(field => field.name == ":method" && field.value == b"POST") {
          self.post_bodies[id] = []
        }
      Event(H3DataReceived(id, bytes)) =>
        if self.post_bodies.get(id) is Some(body) {
          if bytes.length() > 65536 - body.length() {
            fail("smoke body limit exceeded")
          }
          for byte in bytes {
            body.push(byte)
          }
        }
      Event(H3MessageFinished(id)) => {
        let body = match self.post_bodies.get(id) {
          Some(bytes) => Bytes::from_array(bytes)
          None => b"MoonbitHTTP HTTP/3 smoke\n"
        }
        self.post_bodies.remove(id)
        let fields = [
          @http3.QpackField::from_strings(":status", "200").unwrap(),
          @http3.QpackField::from_strings("content-type", "text/plain").unwrap(),
          @http3.QpackField::from_strings(
            "content-length",
            body.length().to_string(),
          ).unwrap(),
        ]
        let (headers, _) = checked(self.h3.encode_headers(id, fields))
        let (data, _) = checked(self.h3.encode_data(body, fin=true))
        self.enqueue(id, headers + data, true)
      }
      ResetStream(id, code) =>
        output.push(
          checked(
            self.tls
            .datagram_driver()
            .reset_stream(id, code.wire_value(), now_ms),
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
        checked(
          self.tls
          .datagram_driver()
          .connection()
          .consume_stream_data(id, bytes.length()),
        )
      }
      _ => output.push(action)
    }
  }
  checked(self.flush_writes(output, now_ms))
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
            if driver.state() == Closed ||
              driver.state() == Draining ||
              now_ms - connection.last_received_ms >= 30000L {
              expired.push(key)
            } else {
              let progress = connection.tls
                .poll(now_ms)
                .bind(actions => {
                  output.append(actions)
                  connection.flush_writes(output, now_ms)
                })
              match progress {
                Ok(_) => ()
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
            h3: @http3.Http3Driver::new(H3Server).unwrap(),
            post_bodies: Map([]),
            writes: Map([]),
            queued_bytes: 0,
            queued_writes: 0,
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
