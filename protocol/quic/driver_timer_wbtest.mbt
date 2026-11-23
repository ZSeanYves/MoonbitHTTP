///|
test "QUIC client probes after its whole Initial flight was acknowledged" {
  for handshake_keys in [false, true] {
    let (client, server) = retirement_security_pair()
    if !handshake_keys {
      client.handshake_send_keys = None
      client.handshake_receive_keys = None
    }
    guard client.send_frames(Initial, [Ping], 0L).unwrap()
      is SendDatagram(_, first) else {
      fail("expected Initial")
    }
    guard server.on_datagram(server.endpoint(), first, 1L).unwrap()
      is [SendDatagram(_, ack)] else {
      fail("expected Initial ACK")
    }
    ignore(client.on_datagram(client.endpoint(), ack, 20L).unwrap())
    assert_eq(client.recovery.bytes_in_flight(), 0L)
    assert_eq(client.poll(79L).unwrap(), [])
    guard client.poll(80L).unwrap() is [SendDatagram(_, probe)] else {
      fail("expected address-validation probe in the available key space")
    }
    if handshake_keys {
      assert_eq(client.key_update.handshake_send_packets, 1L)
    } else {
      assert_eq(probe.length(), 1200)
      assert_eq(client.key_update.initial_send_packets, 2L)
    }
    guard server.on_datagram(server.endpoint(), probe, 81L).unwrap()
      is [SendDatagram(_, reply)] else {
      fail("expected protected probe to elicit an ACK")
    }
    ignore(client.on_datagram(client.endpoint(), reply, 82L).unwrap())
    assert_eq(client.peer_address_validated, handshake_keys)
    if handshake_keys {
      assert_eq(client.poll(2000L).unwrap(), [])
    }
  }
}

///|
test "amplification-blocked PTO uses no number or backoff before credit arrives" {
  let (client, server) = retirement_security_pair()
  server.active_budget.received = 400L
  ignore(server.send_frames(Initial, [Ping], 0L).unwrap())
  assert_eq(server.active_budget.sent, 1200L)
  assert_eq(server.poll(997L).unwrap(), [])
  assert_eq(server.recovery.pto_count(), 0)
  assert_eq(server.key_update.initial_send_packets, 1L)
  guard client.send_frames(Initial, [Ping], 998L).unwrap()
    is SendDatagram(_, ping) else {
    fail("expected additional client datagram")
  }
  ignore(server.on_datagram(server.endpoint(), ping, 998L).unwrap())
  let next = server.next_initial_packet
  guard server.poll(998L).unwrap() is [SendDatagram(_, probe)] else {
    fail("expected retry with fresh credit")
  }
  assert_eq(probe.length(), 1200)
  assert_eq(server.next_initial_packet, next + 1L)
  assert_eq(server.recovery.pto_count(), 1)
  assert_eq(server.poll(998L).unwrap(), [])
}

///|
test "an ACK of an untracked packet proves peer progress at that encryption level" {
  for space in [PacketNumberSpace::Handshake, Application] {
    let (client, server) = retirement_security_pair()
    if space == Application {
      client.establish().unwrap()
      server.establish().unwrap()
    } else {
      server.active_budget.received = 1200L
    }
    guard server.send_frames(space, [Ping], 0L).unwrap()
      is SendDatagram(_, ping) else {
      fail("expected server ping")
    }
    guard client.on_datagram(client.endpoint(), ping, 1L).unwrap()
      is [SendDatagram(_, first_ack)] else {
      fail("expected unpadded ACK")
    }
    assert_eq(client.recovery.bytes_in_flight(), 0L)
    assert_eq(server.on_datagram(server.endpoint(), first_ack, 2L).unwrap(), [])
    let ack = AckFrame::new(0L, 0L, [AckRange::new(0L, 0L).unwrap()]).unwrap()
    guard server.send_frames(space, [Ack(ack)], 3L).unwrap()
      is SendDatagram(_, cumulative) else {
      fail("expected independent acknowledgment")
    }
    ignore(client.on_datagram(client.endpoint(), cumulative, 4L).unwrap())
    assert_true(client.peer_address_validated)
    assert_eq(client.handshake_confirmed(), space == Application)
    assert_eq(client.poll(2000L).unwrap(), [])
  }
}
