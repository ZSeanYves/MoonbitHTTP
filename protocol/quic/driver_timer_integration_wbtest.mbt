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
  let (client, server) = retirement_security_pair(recovery_config={
    ..QuicRecoveryConfig::defaults(),
    max_tracked_packets: 1,
  })
  // PADDING at the last ordinary slot elicits feedback. A server Initial
  // then needs the full 1,200 bytes of amplification credit.
  server.active_budget.received = 399L
  assert_true(
    server.send_frames(Initial, [Padding], 0L) is Err(AmplificationBlocked),
  )
  assert_eq(server.next_initial_packet, 0L)
  server.active_budget.received = 400L
  guard server.send_frames(Initial, [Padding], 0L).unwrap()
    is SendDatagram(_, first) else {
    fail("expected a padded server Initial")
  }
  assert_eq(first.length(), 1200)
  assert_eq(server.active_budget.sent, 1200L)
  assert_eq(server.poll(997L).unwrap(), [])
  assert_eq(server.recovery.pto_count(), 0)
  assert_eq(server.recovery.bytes_in_flight(), 1200L)
  assert_eq(server.recovery.congestion_window(), 12000L)
  assert_eq(server.key_update.initial_send_packets, 1L)
  guard client.send_frames(Initial, [Ping], 998L).unwrap()
    is SendDatagram(_, ping) else {
    fail("expected additional client datagram")
  }
  guard server.on_datagram(server.endpoint(), ping, 998L).unwrap()
    is [SendDatagram(_, ack)] else {
    fail("expected ACK of independent client PING")
  }
  let next = server.next_initial_packet
  guard server.poll(998L).unwrap() is [SendDatagram(_, probe)] else {
    fail("expected retry with fresh credit")
  }
  assert_eq(probe.length(), 1200)
  assert_eq(server.next_initial_packet, next + 1L)
  assert_eq(server.recovery.pto_count(), 1)
  assert_eq(server.recovery.bytes_in_flight(), 2400L)
  assert_eq(server.recovery.congestion_window(), 12000L)
  assert_eq(server.poll(998L).unwrap(), [])
  ignore(client.on_datagram(client.endpoint(), ack, 999L).unwrap())
  assert_true(
    client.on_datagram(client.endpoint(), first, 1000L).unwrap()
    is [SendDatagram(_, _)],
  )
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

///|
test "PTO keeps one payload and makes progress at a one-packet tracking limit" {
  for capacity in [1, 4] {
    let (client, server) = retirement_security_pair(recovery_config={
      ..QuicRecoveryConfig::defaults(),
      max_tracked_packets: capacity,
    })
    guard client.send_frames(Initial, [Crypto(0L, b"hello")], 0L).unwrap()
      is SendDatagram(_, original) else {
      fail("expected Initial CRYPTO")
    }
    let probes = []
    for now in [997L, 2991L] {
      guard client.poll(now).unwrap() is [SendDatagram(_, retry)] else {
        fail("a full queue must still allow a protected probe")
      }
      probes.push(retry)
      assert_eq(retry.length(), original.length())
      assert_eq(client.retransmissions.length(), 1)
      assert_eq(client.recovery.sent.length(), probes.length() + 1)
      assert_eq(
        client.recovery.bytes_in_flight(),
        client.recovery.sent.length().to_int64() * 1200L,
      )
      assert_eq(client.poll(now).unwrap(), [])
      if now == 2991L {
        let delivered = server
          .on_datagram(server.endpoint(), retry, now)
          .unwrap()
        assert_true(delivered.contains(CryptoData(Initial, 0L, b"hello")))
      }
    }
    // The original can still arrive after both probes. Its ACK retires the
    // payload once and only releases bytes that were still in flight.
    guard server.on_datagram(server.endpoint(), original, 2992L).unwrap()
      is [SendDatagram(_, _)] else {
      fail("expected an ACK for the reordered Initial")
    }
    let only_original = AckFrame::new(0L, 0L, [AckRange::new(0L, 0L).unwrap()]).unwrap()
    guard server.send_frames(Initial, [Ack(only_original)], 2992L).unwrap()
      is SendDatagram(_, late) else {
      fail("expected late ACK")
    }
    ignore(client.on_datagram(client.endpoint(), late, 2993L).unwrap())
    assert_true(client.retransmissions.is_empty())
    assert_eq(client.recovery.bytes_in_flight(), 2400L)
    guard server.on_datagram(server.endpoint(), probes[0], 2994L).unwrap()
      is [SendDatagram(_, ack)] else {
      fail("expected cumulative ACK")
    }
    ignore(client.on_datagram(client.endpoint(), ack, 2995L).unwrap())
    assert_eq(client.recovery.bytes_in_flight(), 0L)
  }
}

///|
test "probe history is bounded independently and a delayed ACK reopens ordinary sends" {
  let (client, server) = retirement_security_pair(recovery_config={
    ..QuicRecoveryConfig::defaults(),
    max_tracked_packets: 1,
    max_pto_ms: 1L,
  })
  guard client.send_frames(Handshake, [Crypto(0L, b"a")], 0L).unwrap()
    is SendDatagram(_, first) else {
    fail("expected handshake data")
  }
  guard server.on_datagram(server.endpoint(), first, 0L).unwrap()
    is [CryptoData(_, _, _), SendDatagram(_, first_ack)] else {
    fail("expected ACK to delay")
  }
  let mut last = first
  for i in 1..<(QUIC_PROBE_RESERVE + 1) {
    guard client.poll(i.to_int64()).unwrap() is [SendDatagram(_, retry)] else {
      fail("missing probe")
    }
    last = retry
  }
  let full = QUIC_PROBE_RESERVE.to_int64() + 1L
  assert_eq(client.recovery.sent.length(), 1 + QUIC_PROBE_RESERVE)
  assert_eq(client.retransmissions.length(), 1)
  assert_eq(
    client.poll(full),
    Err(LimitExceeded("QUIC PTO probe reserve", QUIC_PROBE_RESERVE)),
  )
  assert_eq(client.next_handshake_packet, full)
  ignore(client.on_datagram(client.endpoint(), first_ack, full + 1L).unwrap())
  assert_true(client.retransmissions.is_empty())
  assert_eq(client.recovery.probe_numbers.length(), QUIC_PROBE_RESERVE)
  // Releasing the original immediately admits new application-owned CRYPTO
  // even while the independent probe history is still full.
  ignore(client.send_frames(Handshake, [Crypto(1L, b"b")], full + 1L).unwrap())
  guard server.on_datagram(server.endpoint(), last, full + 1L).unwrap()
    is [SendDatagram(_, newest_ack)] else {
    fail("expected ACK for the final probe")
  }
  ignore(client.on_datagram(client.endpoint(), newest_ack, full + 2L).unwrap())
  assert_true(client.recovery.probe_numbers.length() < QUIC_PROBE_RESERVE)
  // Loss detection for old copies precedes the PTO for the new CRYPTO flight.
  assert_eq(client.poll(full + 1000L).unwrap(), [])
  guard client.poll(full + 1001L).unwrap() is [SendDatagram(_, resumed)] else {
    fail("expected a new probe after history was released")
  }
  guard server.on_datagram(server.endpoint(), resumed, full + 1002L).unwrap()
    is [CryptoData(Handshake, 1L, b"b"), SendDatagram(_, ack)] else {
    fail("the new CRYPTO byte must reach the peer")
  }
  ignore(client.on_datagram(client.endpoint(), ack, full + 1003L).unwrap())
  assert_true(client.retransmissions.is_empty())
}

///|
test "padding at either limit elicits feedback and preserves an adjacent ACK" {
  let endpoint = @types.Endpoint::new("udp", "peer.test", 443).unwrap()
  for (capacity, window) in [(1, 12000L), (4096, 1200L)] {
    let (client, server) = key_limit_driver_pair(endpoint, endpoint, recovery_config={
      ..QuicRecoveryConfig::defaults(),
      max_tracked_packets: capacity,
    })
    server.recovery.congestion_window = window
    guard client.send_frames(Application, [Ping], 0L).unwrap()
      is SendDatagram(_, ping) else {
      fail("ping")
    }
    ignore(server.on_datagram(endpoint, ping, 1L).unwrap())
    let ack = AckFrame::new(0L, 0L, [AckRange::new(0L, 0L).unwrap()]).unwrap()
    guard server.send_frames(Application, [Padding, Ack(ack)], 2L).unwrap()
      is SendDatagram(_, feedback) else {
      fail("expected feedback alongside ACK")
    }
    guard client.on_datagram(endpoint, feedback, 3L).unwrap()
      is [SendDatagram(_, response)] else {
      fail("expected the peer to acknowledge this flight")
    }
    assert_eq(client.recovery.bytes_in_flight(), 0L)
    assert_true(server.retransmissions.is_empty())
    assert_eq(server.on_datagram(endpoint, response, 4L).unwrap(), [])
    assert_eq(server.recovery.bytes_in_flight(), 0L)
  }
}
