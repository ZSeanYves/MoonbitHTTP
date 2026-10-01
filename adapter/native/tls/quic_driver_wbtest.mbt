///|
fn exchange_quic_packets(
  client : @quic.QuicTlsDriver[NativeQuicTlsProvider],
  server : @quic.QuicTlsDriver[NativeQuicTlsProvider],
  endpoint : @types.Endpoint,
  initial : Array[(@quic.QuicDriverAction, Bool)],
  now_ms : Int64,
) -> Result[Array[@quic.QuicDriverAction], @quic.QuicError] {
  let queue = initial.copy()
  let delivered : Array[@quic.QuicDriverAction] = []
  let mut steps = 0
  while !queue.is_empty() {
    steps += 1
    if steps > 512 {
      return Err(InvalidPacket("test packet loop did not quiesce"))
    }
    let (action, to_server) = queue.remove(0)
    match action {
      SendDatagram(_, bytes) => {
        // Model a coalesced UDP datagram with invalid trailing bytes. Those
        // bytes cannot erase actions produced by the authenticated Initial.
        let bytes = if (bytes[0].to_int() & 0xf0) == 0xc0 {
          let padded = bytes.to_array()
          padded.append([b'\x00', b'\x00'])
          Bytes::from_array(padded)
        } else {
          bytes
        }
        let next = match
          (if to_server { server } else { client }).on_datagram(
            endpoint,
            bytes,
            now_ms + steps.to_int64(),
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        for action in next {
          queue.push((action, !to_server))
        }
      }
      _ => delivered.push(action)
    }
  }
  Ok(delivered)
}

///|
async test "native QUIC driver: real TLS CRYPTO packets establish h3, exchange data and update keys" {
  let (client_options, server_options) = fixture_options()
  let endpoint = @types.Endpoint::new("udp", "127.0.0.1", 443).unwrap()
  let server_id = @quic.ConnectionId::new(b"server-id").unwrap()
  let client_id = @quic.ConnectionId::new(b"client-id").unwrap()
  let original_id = @quic.ConnectionId::new(b"original").unwrap()
  let transport_params = {
    ..@quic.QuicTransportParams::defaults(),
    max_udp_payload_size: 1400,
  }
  let client_packets = @quic.QuicDatagramDriver::new(
    Client,
    endpoint,
    original_id,
    client_id,
    original_id,
    transport_params~,
  ).unwrap()
  let server_packets = @quic.QuicDatagramDriver::new(
    Server,
    endpoint,
    original_id,
    server_id,
    client_id,
    transport_params~,
  ).unwrap()
  let client_tls = NativeQuicTlsProvider::new(allow_system_roots=false)
  let server_tls = NativeQuicTlsProvider::new(
    server=true,
    allow_system_roots=false,
  )
  defer {
    client_tls.close()
    server_tls.close()
  }
  let client = @quic.QuicTlsDriver::new(client_packets, client_tls).unwrap()
  let server = @quic.QuicTlsDriver::new(server_packets, server_tls).unwrap()
  let actions : Array[(@quic.QuicDriverAction, Bool)] = []
  let client_start = match
    client.start({ ..client_options, alpn: ["h3"], }, 0L) {
    Ok(actions) => actions
    Err(error) => fail("native QUIC client start failed: \{Repr(error)}")
  }
  for action in client_start {
    actions.push((action, true))
  }
  let server_start = match
    server.start({ ..server_options, alpn: ["h3"], }, 0L) {
    Ok(actions) => actions
    Err(error) => fail("native QUIC server start failed: \{Repr(error)}")
  }
  for action in server_start {
    actions.push((action, false))
  }
  ignore(exchange_quic_packets(client, server, endpoint, actions, 1L).unwrap())
  assert_eq(client_packets.state(), Established)
  assert_eq(server_packets.state(), Established)
  assert_true(client_packets.handshake_confirmed())
  assert_true(server_packets.handshake_confirmed())
  let stream = client_packets.connection().open_bidirectional_stream().unwrap()
  let frame = @quic.StreamFrame::new(stream, 0L, b"authenticated", false).unwrap()
  let packet = client_packets
    .send_frames(Application, [Stream(frame)], 100L)
    .unwrap()
  let delivery = exchange_quic_packets(
    client,
    server,
    endpoint,
    [(packet, true)],
    101L,
  ).unwrap()
  assert_true(delivery.contains(StreamData(stream, b"authenticated", false)))
  client_packets.initiate_key_update().unwrap()
  let frame = @quic.StreamFrame::new(stream, 13L, b"updated", true).unwrap()
  let packet = client_packets
    .send_frames(Application, [Stream(frame)], 200L)
    .unwrap()
  let delivery = exchange_quic_packets(
    client,
    server,
    endpoint,
    [(packet, true)],
    201L,
  ).unwrap()
  assert_true(delivery.contains(StreamData(stream, b"updated", true)))
}
