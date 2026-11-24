///|
fn qpack_test_field(name : String, value : String) -> @http3.QpackField {
  @http3.QpackField::from_strings(name, value).unwrap()
}

///|
fn driver_request_fields() -> Array[@http3.QpackField] {
  [
    qpack_test_field(":method", "GET"),
    qpack_test_field(":scheme", "https"),
    qpack_test_field(":authority", "example.com"),
    qpack_test_field(":path", "/"),
  ]
}

///|
struct SessionPeer {
  packets : @quic.QuicDatagramDriver
  session : @http3.Http3Session
  events : Array[@http3.Http3SessionAction]
}

///|
fn session_peer(
  role : @quic.QuicRole,
  endpoint : @types.Endpoint,
  local_id : @quic.ConnectionId,
  remote_id : @quic.ConnectionId,
  destination : @quic.ConnectionId,
  queue_limit : Int32,
  stream_window~ : Int64 = 1048576L,
  request_slots~ : Int64 = 1L,
) -> SessionPeer {
  let params = {
    ..@quic.QuicTransportParams::defaults(),
    initial_max_streams_bidi: request_slots,
    initial_max_stream_data_bidi_remote: stream_window,
  }
  let packets = @quic.QuicDatagramDriver::new(
    role,
    endpoint,
    destination,
    local_id,
    remote_id,
    transport_params=params,
  ).unwrap()
  let tls = @quic.QuicTlsDriver::new(packets, ()).unwrap()
  let session = @http3.Http3Session::new(tls, max_pending_writes=queue_limit).unwrap()
  // Deterministic traffic keys let this transport/session test run on all
  // backends. The independent network test exercises the native TLS provider.
  let (c, s) = @quic.quic_initial_packet_keys(destination).unwrap()
  let (send, recv) = if role == Client { (c, s) } else { (s, c) }
  packets.install_handshake_keys(send, recv).unwrap()
  packets.install_application_keys(send, recv).unwrap()
  let original = if role == Client { Some(destination) } else { None }
  packets
  .set_peer_transport_parameters(
    @quic.QuicTransportParameters::new(
      remote_id,
      limits=params,
      original_destination_connection_id=original,
    ),
  )
  .unwrap()
  packets.establish().unwrap()
  { packets, session, events: [], }
}

///|
fn pump_sessions(
  client : SessionPeer,
  server : SessionPeer,
  now : Int64,
  poll_server~ : Bool = true,
) -> Unit raise {
  let queue : Array[(Bool, @quic.QuicDriverAction)] = []
  fn collect(
    peer : SessionPeer,
    to_server : Bool,
    actions : Array[@quic.QuicDriverAction],
  ) -> Unit raise {
    for action in peer.session.advance(actions, now) {
      match action {
        Transport(SendDatagram(_, _) as packet) =>
          queue.push((to_server, packet))
        Failed(error) => fail("session failed: \{Repr(error)}")
        other => peer.events.push(other)
      }
    }
  }
  collect(client, true, client.packets.poll(now).unwrap())
  if poll_server {
    collect(server, false, server.packets.poll(now).unwrap())
  }
  for index = 0; index < queue.length(); index = index + 1 {
    guard index < 512 else { fail("session exchange did not quiesce") }
    let (to_server, packet) = queue[index]
    if packet is SendDatagram(_, bytes) {
      let peer = if to_server { server } else { client }
      collect(
        peer,
        !to_server,
        peer.packets.on_datagram(peer.packets.endpoint(), bytes, now).unwrap(),
      )
    }
  }
}

///|
test "http3 session: backpressure retries preserve stream identifiers, body length and trailers" {
  let endpoint = @types.Endpoint::new("udp", "localhost", 443).unwrap()
  let c = @quic.ConnectionId::new(b"clientid").unwrap()
  let s = @quic.ConnectionId::new(b"serverid").unwrap()
  let client = session_peer(Client, endpoint, c, s, s, 1)
  let server = session_peer(Server, endpoint, s, c, s, 8)
  pump_sessions(client, server, 10L)
  let fields = driver_request_fields()
  fields.push(qpack_test_field("content-length", "5"))
  assert_true(
    client.session.start_request(fields, fin=true)
    is Err(Http3Protocol(Http3StreamError(0L, H3MessageError, _))),
  )
  let id = client.session.start_request(fields).unwrap()
  assert_eq(id, 0L)
  assert_true(
    client.session.send_data(id, b"hello", fin=true) is Err(Http3WriteBlocked),
  )
  pump_sessions(client, server, 20L)
  assert_true(
    client.session.start_request(driver_request_fields(), fin=true)
    is Err(Http3Transport(FlowControl(_, _))),
  )
  assert_true(
    client.session.send_data(id, b"x", fin=true)
    is Err(Http3StreamError(_, H3MessageError, _)),
  )
  client.session.send_data(id, b"hello", fin=true).unwrap()
  pump_sessions(client, server, 30L)
  assert_true(server.events.contains(Message(H3DataReceived(id, b"hello"))))
  assert_true(server.events.contains(Message(H3MessageFinished(id))))
  let hints = [qpack_test_field(":status", "103")]
  assert_true(
    server.session.send_headers(id, hints, fin=true)
    is Err(Http3StreamError(_, H3RequestIncomplete, _)),
  )
  server.session.send_headers(id, hints).unwrap()
  server.session
  .send_headers(id, [
    qpack_test_field(":status", "200"),
    qpack_test_field("content-length", "2"),
  ])
  .unwrap()
  server.session.send_data(id, b"ok").unwrap()
  let trailer = [qpack_test_field("x-check", "done")]
  server.session.send_headers(id, trailer).unwrap()
  server.session.finish(id).unwrap()
  assert_true(server.session.writes_pending())
  for tick in 0..<6 {
    pump_sessions(client, server, 40L + tick.to_int64() * 20L)
  }
  assert_true(
    client.events.contains(Message(H3HeadersReceived(id, hints, false, true))),
  )
  assert_true(
    client.events.contains(Message(H3HeadersReceived(id, trailer, true, false))),
  )
  assert_true(client.events.contains(Message(H3MessageFinished(id))))
  assert_false(server.session.writes_pending())
  assert_eq(
    client.session.start_request(driver_request_fields(), fin=true),
    Ok(4L),
  )
}

///|
test "http3 session: body consumption returns only the requested amount of receive credit" {
  let endpoint = @types.Endpoint::new("udp", "localhost", 443).unwrap()
  let c = @quic.ConnectionId::new(b"clientid").unwrap()
  let s = @quic.ConnectionId::new(b"serverid").unwrap()
  let client = session_peer(Client, endpoint, c, s, s, 8, stream_window=128L)
  let server = session_peer(Server, endpoint, s, c, s, 8, stream_window=128L)
  server.session.defer_body_credit()
  pump_sessions(client, server, 0L)
  let id = client.session.start_request(driver_request_fields()).unwrap()
  client.session
  .send_data(id, Bytes::from_array(FixedArray::make(512, b'a')), fin=true)
  .unwrap()
  fn delivered() -> Int32 {
    server.events.fold(init=0, (sum, event) => {
      match event {
        Message(H3DataReceived(stream, bytes)) if stream == id =>
          sum + bytes.length()
        _ => sum
      }
    })
  }
  for tick in 1..<10 {
    pump_sessions(client, server, tick.to_int64() * 30L)
  }
  let first = delivered()
  assert_true(first > 0 && first <= 128)
  server.session.consume_body(id, 17).unwrap()
  for tick in 10..<16 {
    pump_sessions(client, server, tick.to_int64() * 30L)
  }
  assert_eq(delivered(), first + 17)
  let mut consumed = 17
  for tick in 16..<35 {
    let received = delivered()
    server.session.consume_body(id, received - consumed).unwrap()
    consumed = received
    pump_sessions(client, server, tick.to_int64() * 30L)
  }
  assert_eq(delivered(), 512)
  assert_true(server.events.contains(Message(H3MessageFinished(id))))
}

///|
test "http3 session: GOAWAY rejects a crossing request and preserves the accepted response" {
  let endpoint = @types.Endpoint::new("udp", "localhost", 443).unwrap()
  let c = @quic.ConnectionId::new(b"clientid").unwrap()
  let s = @quic.ConnectionId::new(b"serverid").unwrap()
  let client = session_peer(Client, endpoint, c, s, s, 8, request_slots=2L)
  let server = session_peer(Server, endpoint, s, c, s, 1, request_slots=2L)
  pump_sessions(client, server, 0L)
  let accepted = client.session
    .start_request(driver_request_fields(), fin=true)
    .unwrap()
  pump_sessions(client, server, 10L)
  assert_true(server.events.contains(Message(H3MessageFinished(accepted))))
  let late = client.session
    .start_request(driver_request_fields(), fin=true)
    .unwrap()
  assert_true(
    server.session.send_goaway(1L) is Err(Http3ConnectionError(H3IdError, _)),
  )
  server.session.send_goaway(12L).unwrap()
  server.session.send_goaway(8L).unwrap()
  server.session.send_goaway(late).unwrap()
  server.session.send_goaway(late).unwrap()
  assert_true(
    server.session.send_goaway(12L) is Err(Http3ConnectionError(H3IdError, _)),
  )
  server.session
  .send_headers(accepted, [qpack_test_field(":status", "204")], fin=true)
  .unwrap()
  // Receive the late request before the server can empty its three control
  // queue entries. Its cancellation must survive that backpressure.
  pump_sessions(client, server, 11L, poll_server=false)
  for tick in 1..<15 {
    pump_sessions(client, server, tick.to_int64() * 25L)
  }
  let cutoffs = client.events.filter_map(fn(event) {
    if event is Message(H3GoawayReceived(first)) {
      Some(first)
    } else {
      None
    }
  })
  assert_eq(cutoffs, [12L, 8L, late])
  assert_true(client.events.contains(Message(H3MessageFinished(accepted))))
  assert_true(client.events.contains(Transport(StreamReset(late, 0x10bL))))
  assert_false(
    server.events.any(event => {
      event is Message(H3HeadersReceived(id, _, _, _)) && id == late
    }),
  )
  assert_true(
    client.session.start_request(driver_request_fields())
    is Err(Http3Protocol(Http3StreamError(_, H3RequestRejected, _))),
  )
  guard server.session.close(500L).unwrap() is Some(SendDatagram(_, bytes)) else {
    fail("server did not send a closing packet")
  }
  ignore(client.packets.on_datagram(endpoint, bytes, 500L).unwrap())
  assert_eq(
    client.packets.connection().peer_close(),
    Some(ApplicationClose(0x100L, "")),
  )
  assert_true(@http3.peer_closed_normally(client.packets.connection()))
  // The same number in the transport error space denotes a TLS alert.
  ignore(
    server.packets
    .connection()
    .receive_frame(ConnectionClose(true, 0x100L, 0L, b"alert"))
    .unwrap(),
  )
  assert_false(@http3.peer_closed_normally(server.packets.connection()))
  assert_eq(server.packets.connection().close_reason(), Some((0x100L, "alert")))
}
