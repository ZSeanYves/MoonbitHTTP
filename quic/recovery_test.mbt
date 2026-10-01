///|
test "quic recovery: ACK samples RTT and releases bytes" {
  let recovery = @quic.QuicRecovery::new(now_ms=0L).unwrap()
  recovery
  .on_packet_sent({
    number: 0L,
    space: Initial,
    bytes: 1200,
    sent_at_ms: 10L,
    ack_eliciting: true,
    retransmittable: true,
  })
  .unwrap()
  let range = @quic.AckRange::new(0L, 0L).unwrap()
  let ack = @quic.AckFrame::new(0L, 0L, [range]).unwrap()
  let events = recovery.on_ack(Initial, ack, 35L).unwrap()
  assert_eq(events.length(), 1)
  assert_eq(recovery.bytes_in_flight(), 0L)
  assert_eq(recovery.smoothed_rtt_ms(), Some(25L))
}

///|
test "quic recovery: packet threshold loss and PTO are bounded" {
  let recovery = @quic.QuicRecovery::new(now_ms=0L).unwrap()
  for number in 0L..<4L {
    recovery
    .on_packet_sent({
      number,
      space: Application,
      bytes: 1200,
      sent_at_ms: 0L,
      ack_eliciting: true,
      retransmittable: true,
    })
    .unwrap()
  }
  ignore(
    recovery
    .on_ack(
      Application,
      @quic.AckFrame::new(3L, 0L, [@quic.AckRange::new(3L, 3L).unwrap()]).unwrap(),
      100L,
    )
    .unwrap(),
  )
  let lost = recovery.detect_loss(Application, 1000L).unwrap()
  assert_eq(lost.length(), 3)
  let probe_recovery = @quic.QuicRecovery::new(now_ms=0L).unwrap()
  probe_recovery
  .on_packet_sent({
    number: 0L,
    space: Handshake,
    bytes: 1200,
    sent_at_ms: 0L,
    ack_eliciting: true,
    retransmittable: true,
  })
  .unwrap()
  let probe = probe_recovery.poll(2000L).unwrap()
  assert_eq(probe, [ProbeTimeout(Handshake)])
}

///|
test "quic recovery: PTO keeps original packet for late ACK accounting" {
  let recovery = @quic.QuicRecovery::new(now_ms=0L).unwrap()
  let original : @quic.QuicSentPacket = {
    number: 0L,
    space: Handshake,
    bytes: 1200,
    sent_at_ms: 0L,
    ack_eliciting: true,
    retransmittable: true,
  }
  recovery.on_packet_sent(original).unwrap()
  assert_eq(recovery.poll(997L).unwrap(), [ProbeTimeout(Handshake)])
  // Selecting a PTO source must not remove the original packet or release its
  // congestion accounting; the probe is sent with a new packet number.
  assert_eq(recovery.oldest_probe_packet(Handshake), Some(original))
  assert_eq(recovery.bytes_in_flight(), 1200L)
  let ack = @quic.AckFrame::new(0L, 0L, [@quic.AckRange::new(0L, 0L).unwrap()]).unwrap()
  assert_eq(recovery.on_ack(Handshake, ack, 1000L).unwrap().length(), 1)
  assert_eq(recovery.bytes_in_flight(), 0L)
}

///|
test "quic recovery: time threshold never loses packets above the largest ACK" {
  let recovery = @quic.QuicRecovery::new(now_ms=0L).unwrap()
  for number in 0L..<3L {
    recovery
    .on_packet_sent({
      number,
      space: Application,
      bytes: 1200,
      sent_at_ms: 0L,
      ack_eliciting: true,
      retransmittable: true,
    })
    .unwrap()
  }
  ignore(
    recovery
    .on_ack(
      Application,
      @quic.AckFrame::new(0L, 0L, [@quic.AckRange::new(0L, 0L).unwrap()]).unwrap(),
      10L,
    )
    .unwrap(),
  )
  assert_eq(recovery.detect_loss(Application, 100000L).unwrap(), [])
}

///|
test "quic recovery: handshake PTO excludes application ACK delay and backs off exponentially" {
  let recovery = @quic.QuicRecovery::new(now_ms=0L).unwrap()
  recovery
  .on_packet_sent({
    number: 0L,
    space: Handshake,
    bytes: 1200,
    sent_at_ms: 0L,
    ack_eliciting: true,
    retransmittable: true,
  })
  .unwrap()
  // Initial RTT 333 plus 4*RTTVAR 666; the peer ACK delay is not included
  // until the Application packet number space is active.
  assert_eq(recovery.poll(996L).unwrap(), [])
  assert_eq(recovery.poll(997L).unwrap(), [ProbeTimeout(Handshake)])
  assert_eq(recovery.poll(1993L).unwrap(), [])
  assert_eq(recovery.poll(1994L).unwrap(), [ProbeTimeout(Handshake)])
}

///|
test "quic recovery: non-ACK receive does not reset PTO backoff" {
  let recovery = @quic.QuicRecovery::new(now_ms=0L).unwrap()
  recovery
  .on_packet_sent({
    number: 0L,
    space: Handshake,
    bytes: 1200,
    sent_at_ms: 0L,
    ack_eliciting: true,
    retransmittable: true,
  })
  .unwrap()
  assert_eq(recovery.poll(997L).unwrap(), [ProbeTimeout(Handshake)])
  recovery.on_receive(1000L).unwrap()
  assert_eq(recovery.poll(1993L).unwrap(), [])
  assert_eq(recovery.poll(1994L).unwrap(), [ProbeTimeout(Handshake)])
}

///|
test "quic recovery: application PTO waits for handshake confirmation" {
  let recovery = @quic.QuicRecovery::new(now_ms=0L).unwrap()
  recovery
  .on_packet_sent({
    number: 0L,
    space: Application,
    bytes: 1200,
    sent_at_ms: 0L,
    ack_eliciting: true,
    retransmittable: true,
  })
  .unwrap()
  assert_eq(recovery.poll(2000L, application_confirmed=false).unwrap(), [])
  assert_eq(recovery.poll(1022L, application_confirmed=true).unwrap(), [
    ProbeTimeout(Application),
  ])
}

///|
test "quic recovery: loss reduction is not repeated by an empty scan" {
  let recovery = @quic.QuicRecovery::new(now_ms=0L).unwrap()
  for number in 0L..<4L {
    recovery
    .on_packet_sent({
      number,
      space: Application,
      bytes: 1200,
      sent_at_ms: 0L,
      ack_eliciting: true,
      retransmittable: true,
    })
    .unwrap()
  }
  ignore(
    recovery
    .on_ack(
      Application,
      @quic.AckFrame::new(3L, 0L, [@quic.AckRange::new(3L, 3L).unwrap()]).unwrap(),
      100L,
    )
    .unwrap(),
  )
  let before = recovery.congestion_window()
  assert_eq(recovery.detect_loss(Application, 1000L).unwrap().length(), 3)
  let after = recovery.congestion_window()
  assert_true(after < before)
  assert_eq(recovery.detect_loss(Application, 2000L).unwrap(), [])
  assert_eq(recovery.congestion_window(), after)
}

///|
test "quic recovery: ACK-only packets do not end a loss epoch" {
  let recovery = @quic.QuicRecovery::new().unwrap()
  for number in 0L..<4L {
    recovery
    .on_packet_sent({
      number,
      space: Application,
      bytes: 1200,
      sent_at_ms: 0L,
      ack_eliciting: true,
      retransmittable: true,
    })
    .unwrap()
  }
  ignore(
    recovery
    .on_ack(
      Application,
      @quic.AckFrame::new(3L, 0L, [@quic.AckRange::new(3L, 3L).unwrap()]).unwrap(),
      100L,
    )
    .unwrap(),
  )
  ignore(recovery.detect_loss(Application, 1000L).unwrap())
  let after_loss = recovery.congestion_window()
  recovery
  .on_packet_sent({
    number: 4L,
    space: Application,
    bytes: 1200,
    sent_at_ms: 1000L,
    ack_eliciting: false,
    retransmittable: true,
  })
  .unwrap()
  ignore(
    recovery
    .on_ack(
      Application,
      @quic.AckFrame::new(4L, 0L, [@quic.AckRange::new(4L, 4L).unwrap()]).unwrap(),
      1100L,
    )
    .unwrap(),
  )
  assert_eq(recovery.congestion_window(), after_loss)
  recovery
  .on_packet_sent({
    number: 5L,
    space: Application,
    bytes: 1200,
    sent_at_ms: 1100L,
    ack_eliciting: true,
    retransmittable: true,
  })
  .unwrap()
  ignore(
    recovery
    .on_ack(
      Application,
      @quic.AckFrame::new(5L, 0L, [@quic.AckRange::new(5L, 5L).unwrap()]).unwrap(),
      1200L,
    )
    .unwrap(),
  )
  assert_true(recovery.congestion_window() > after_loss)
}

///|
test "quic recovery: idle timeout is explicit and monotonic" {
  let recovery = @quic.QuicRecovery::new(now_ms=0L).unwrap()
  assert_eq(recovery.poll(29999L).unwrap().length(), 0)
  assert_eq(recovery.poll(30000L).unwrap(), [IdleTimeout])
  assert_true(recovery.on_receive(-1L) is Err(_))
}

///|
test "quic recovery: ACK cannot acknowledge an unsent packet" {
  let recovery = @quic.QuicRecovery::new(now_ms=0L).unwrap()
  recovery
  .on_packet_sent({
    number: 0L,
    space: Application,
    bytes: 1200,
    sent_at_ms: 0L,
    ack_eliciting: true,
    retransmittable: true,
  })
  .unwrap()
  let forged = @quic.AckFrame::new(1L, 0L, [
    @quic.AckRange::new(1L, 1L).unwrap(),
  ]).unwrap()
  assert_true(recovery.on_ack(Application, forged, 1L) is Err(Protocol(_)))
  assert_eq(recovery.bytes_in_flight(), 1200L)
}

///|
test "quic recovery: packet spaces retain independent loss baselines" {
  let recovery = @quic.QuicRecovery::new(now_ms=0L).unwrap()
  for number in 0L..<4L {
    recovery
    .on_packet_sent({
      number,
      space: Initial,
      bytes: 100,
      sent_at_ms: 0L,
      ack_eliciting: true,
      retransmittable: true,
    })
    .unwrap()
  }
  recovery
  .on_packet_sent({
    number: 0L,
    space: Handshake,
    bytes: 100,
    sent_at_ms: 0L,
    ack_eliciting: true,
    retransmittable: true,
  })
  .unwrap()
  let initial_ack = @quic.AckFrame::new(3L, 0L, [
    @quic.AckRange::new(3L, 3L).unwrap(),
  ]).unwrap()
  ignore(recovery.on_ack(Initial, initial_ack, 10L).unwrap())
  let handshake_ack = @quic.AckFrame::new(0L, 0L, [
    @quic.AckRange::new(0L, 0L).unwrap(),
  ]).unwrap()
  ignore(recovery.on_ack(Handshake, handshake_ack, 10L).unwrap())
  let lost = recovery.detect_loss(Initial, 10L).unwrap()
  assert_true(lost.any(fn(event) { event is PacketLost(0L, Initial, 100) }))
}

///|
test "quic recovery: congestion rejection is atomic and ACK-only is exempt" {
  let recovery = @quic.QuicRecovery::new(now_ms=0L).unwrap()
  for number in 0L..<10L {
    recovery
    .on_packet_sent({
      number,
      space: Application,
      bytes: 1200,
      sent_at_ms: number,
      ack_eliciting: true,
      retransmittable: true,
    })
    .unwrap()
  }
  let blocked : @quic.QuicSentPacket = {
    number: 10L,
    space: Application,
    bytes: 1200,
    sent_at_ms: 10L,
    ack_eliciting: true,
    retransmittable: true,
  }
  assert_true(recovery.on_packet_sent(blocked) is Err(FlowControl(_)))
  recovery
  .on_packet_sent({
    number: 10L,
    space: Application,
    bytes: 80,
    sent_at_ms: 10L,
    ack_eliciting: false,
    retransmittable: false,
  })
  .unwrap()
  assert_eq(recovery.bytes_in_flight(), 12000L)
}

///|
test "quic recovery: ACK delay is capped only after handshake confirmation" {
  for confirmed in [false, true] {
    let recovery = @quic.QuicRecovery::new().unwrap()
    for number in 0L..<2L {
      recovery
      .on_packet_sent({
        number,
        space: Application,
        bytes: 100,
        sent_at_ms: number * 200L,
        ack_eliciting: true,
        retransmittable: true,
      })
      .unwrap()
      ignore(
        recovery
        .on_ack(
          Application,
          @quic.AckFrame::new(number, number * 100000L, [
            @quic.AckRange::new(number, number).unwrap(),
          ]).unwrap(),
          if number == 0L {
            100L
          } else {
            400L
          },
          ack_delay_exponent=0,
          handshake_confirmed=confirmed,
        )
        .unwrap(),
      )
    }
    // The second RTT is 200ms with a reported 100ms ACK delay. The first
    // 100ms sample establishes min_rtt. After confirmation only 25ms of
    // delay can be subtracted; before it, all 100ms can be subtracted.
    assert_eq(
      recovery.smoothed_rtt_ms(),
      Some(if confirmed { 109L } else { 100L }),
    )
  }
}

///|
test "quic recovery: Initial ACK delay is ignored before confirmation" {
  let recovery = @quic.QuicRecovery::new().unwrap()
  for number in 0L..<2L {
    recovery
    .on_packet_sent({
      number,
      space: Initial,
      bytes: 100,
      sent_at_ms: number * 200L,
      ack_eliciting: true,
      retransmittable: true,
    })
    .unwrap()
    ignore(
      recovery
      .on_ack(
        Initial,
        @quic.AckFrame::new(number, number * 100000L, [
          @quic.AckRange::new(number, number).unwrap(),
        ]).unwrap(),
        if number == 0L {
          100L
        } else {
          400L
        },
        ack_delay_exponent=0,
        handshake_confirmed=false,
      )
      .unwrap(),
    )
  }
  assert_eq(recovery.smoothed_rtt_ms(), Some(112L))
}

///|
test "quic recovery: unvalidated client ACK retains PTO backoff" {
  let recovery = @quic.QuicRecovery::new().unwrap()
  recovery
  .on_packet_sent({
    number: 0L,
    space: Initial,
    bytes: 1200,
    sent_at_ms: 0L,
    ack_eliciting: true,
    retransmittable: true,
  })
  .unwrap()
  assert_eq(recovery.poll(997L).unwrap(), [ProbeTimeout(Initial)])
  ignore(
    recovery
    .on_ack(
      Initial,
      @quic.AckFrame::new(0L, 0L, [@quic.AckRange::new(0L, 0L).unwrap()]).unwrap(),
      1000L,
      reset_pto=false,
      handshake_confirmed=false,
    )
    .unwrap(),
  )
  assert_eq(recovery.pto_count(), 1)
}

///|
test "quic recovery: loss epochs use send order across packet spaces" {
  let recovery = @quic.QuicRecovery::new().unwrap()
  for number in 0L..<8L {
    recovery
    .on_packet_sent({
      number,
      space: Initial,
      bytes: 100,
      sent_at_ms: 0L,
      ack_eliciting: true,
      retransmittable: true,
    })
    .unwrap()
  }
  recovery
  .on_packet_sent({
    number: 0L,
    space: Handshake,
    bytes: 100,
    sent_at_ms: 0L,
    ack_eliciting: true,
    retransmittable: true,
  })
  .unwrap()
  ignore(
    recovery
    .on_ack(
      Initial,
      @quic.AckFrame::new(3L, 0L, [@quic.AckRange::new(3L, 3L).unwrap()]).unwrap(),
      100L,
    )
    .unwrap(),
  )
  assert_eq(recovery.detect_loss(Initial, 100L).unwrap().length(), 1)
  let first_reduction = recovery.congestion_window()
  ignore(
    recovery
    .on_ack(
      Handshake,
      @quic.AckFrame::new(0L, 0L, [@quic.AckRange::new(0L, 0L).unwrap()]).unwrap(),
      101L,
    )
    .unwrap(),
  )
  // An old ACK from a different space neither ends recovery nor grows cwnd.
  assert_eq(recovery.congestion_window(), first_reduction)
  assert_eq(recovery.detect_loss(Initial, 114L).unwrap().length(), 2)
  assert_eq(recovery.congestion_window(), first_reduction)
  for number in 1L..<5L {
    recovery
    .on_packet_sent({
      number,
      space: Handshake,
      bytes: 100,
      sent_at_ms: 114L,
      ack_eliciting: true,
      retransmittable: true,
    })
    .unwrap()
  }
  ignore(
    recovery
    .on_ack(
      Handshake,
      @quic.AckFrame::new(4L, 0L, [@quic.AckRange::new(4L, 4L).unwrap()]).unwrap(),
      200L,
    )
    .unwrap(),
  )
  assert_true(recovery.congestion_window() > first_reduction)
  // The newer Handshake ACK ends the Initial loss epoch. A loss in this new
  // flight now starts a second epoch even though its packet space differs.
  assert_eq(recovery.detect_loss(Handshake, 200L).unwrap().length(), 1)
  let second_reduction = recovery.congestion_window()
  assert_true(second_reduction < first_reduction)
  ignore(
    recovery
    .on_ack(
      Initial,
      @quic.AckFrame::new(7L, 0L, [@quic.AckRange::new(7L, 7L).unwrap()]).unwrap(),
      201L,
    )
    .unwrap(),
  )
  // Only the oldest unacknowledged packet is past the packet threshold at
  // this clock value; the newer packets remain eligible for a later timer.
  assert_eq(recovery.detect_loss(Initial, 201L).unwrap().length(), 1)
  assert_eq(recovery.congestion_window(), second_reduction)
}
