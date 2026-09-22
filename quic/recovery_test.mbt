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
