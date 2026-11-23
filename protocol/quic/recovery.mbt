///|
/// Configuration for the RFC 9002-style loss recovery engine. The engine is
/// deliberately independent of a socket: a driver supplies packet numbers,
/// acknowledgements and a monotonic clock, then turns the returned events into
/// datagrams or retransmissions.
pub(all) struct QuicRecoveryConfig {
  max_ack_delay_ms : Int64
  max_pto_ms : Int64
  idle_timeout_ms : Int64
  initial_rtt_ms : Int64
  max_tracked_packets : Int
} derive(Eq, Debug)

///|
pub fn QuicRecoveryConfig::defaults() -> QuicRecoveryConfig {
  {
    max_ack_delay_ms: 25L,
    max_pto_ms: 60000L,
    idle_timeout_ms: 30000L,
    initial_rtt_ms: 333L,
    max_tracked_packets: 4096,
  }
}

///|
pub fn QuicRecoveryConfig::validate(
  self : QuicRecoveryConfig,
) -> Result[Unit, QuicError] {
  if self.max_ack_delay_ms < 0L ||
    self.max_pto_ms <= 0L ||
    self.idle_timeout_ms <= 0L ||
    self.initial_rtt_ms <= 0L ||
    self.max_tracked_packets <= 0 {
    return Err(InvalidTransportParameter("invalid recovery timing"))
  }
  Ok(())
}

///|
pub(all) struct QuicSentPacket {
  number : Int64
  space : PacketNumberSpace
  bytes : Int
  sent_at_ms : Int64
  ack_eliciting : Bool
  retransmittable : Bool
} derive(Eq, Debug)

///|
pub fn QuicSentPacket::number(self : QuicSentPacket) -> Int64 {
  self.number
}

///|
pub fn QuicSentPacket::space(self : QuicSentPacket) -> PacketNumberSpace {
  self.space
}

///|
pub fn QuicSentPacket::bytes(self : QuicSentPacket) -> Int {
  self.bytes
}

///|
pub fn QuicSentPacket::retransmittable(self : QuicSentPacket) -> Bool {
  self.retransmittable
}

///|
pub(all) enum QuicRecoveryEvent {
  PacketAcknowledged(Int64, PacketNumberSpace, Int)
  PacketLost(Int64, PacketNumberSpace, Int)
  ProbeTimeout(PacketNumberSpace)
  IdleTimeout
} derive(Eq, Debug)

///|
pub(all) struct QuicRecovery {
  config : QuicRecoveryConfig
  mut peer_max_ack_delay_ms : Int64
  sent : Array[QuicSentPacket]
  // Only packets that need padding to count as in flight require an entry.
  priv padded_non_eliciting : Set[(PacketNumberSpace, Int64)]
  // An unpadded ACK can be the largest number in a mixed ACK. Its timestamp
  // is optional RTT history and must never consume a recovery admission slot.
  priv recent_untracked : Map[(PacketNumberSpace, Int64), QuicSentPacket]
  priv timers : (QuicSpaceTimer, QuicSpaceTimer, QuicSpaceTimer)
  priv mut restart_idle_on_send : Bool
  mut bytes_in_flight : Int64
  mut largest_initial_sent : Int64
  mut largest_handshake_sent : Int64
  mut largest_application_sent : Int64
  mut largest_initial_acked : Int64
  mut largest_handshake_acked : Int64
  mut largest_application_acked : Int64
  mut min_rtt_ms : Int64?
  mut latest_rtt_ms : Int64?
  mut smoothed_rtt_ms : Int64?
  mut rttvar_ms : Int64?
  mut pto_count : Int
  mut last_activity_ms : Int64
  mut last_probe_ms : Int64?
  mut congestion_window : Int64
  mut ssthresh : Int64
  mut in_recovery : Bool
  // A loss epoch is global to the path, but packet numbers are per space.
  // Snapshot all three largest-sent numbers to distinguish later sends even
  // when several packets share a clock tick or the ACK uses another space.
  mut recovery_end : (Int64, Int64, Int64)?
} derive(Debug)

///|
pub fn QuicRecovery::new(
  config? : QuicRecoveryConfig = QuicRecoveryConfig::defaults(),
  now_ms? : Int64 = 0L,
) -> Result[QuicRecovery, QuicError] {
  match config.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if now_ms < 0L {
    return Err(InvalidPacket("recovery clock cannot be negative"))
  }
  Ok({
    config,
    peer_max_ack_delay_ms: config.max_ack_delay_ms,
    sent: [],
    padded_non_eliciting: Set([]),
    recent_untracked: {},
    timers: (
      QuicSpaceTimer::new(),
      QuicSpaceTimer::new(),
      QuicSpaceTimer::new(),
    ),
    restart_idle_on_send: true,
    bytes_in_flight: 0L,
    largest_initial_sent: -1L,
    largest_handshake_sent: -1L,
    largest_application_sent: -1L,
    largest_initial_acked: -1L,
    largest_handshake_acked: -1L,
    largest_application_acked: -1L,
    min_rtt_ms: None,
    latest_rtt_ms: None,
    smoothed_rtt_ms: None,
    rttvar_ms: None,
    pto_count: 0,
    last_activity_ms: now_ms,
    last_probe_ms: None,
    congestion_window: 10L * 1200L,
    ssthresh: QUIC_MAX_VARINT,
    in_recovery: false,
    recovery_end: None,
  })
}

///|
pub fn QuicRecovery::bytes_in_flight(self : QuicRecovery) -> Int64 {
  self.bytes_in_flight
}

///|
pub fn QuicRecovery::congestion_window(self : QuicRecovery) -> Int64 {
  self.congestion_window
}

///|
pub fn QuicRecovery::smoothed_rtt_ms(self : QuicRecovery) -> Int64? {
  self.smoothed_rtt_ms
}

///|
pub fn QuicRecovery::pto_count(self : QuicRecovery) -> Int {
  self.pto_count
}

///|
fn QuicRecovery::largest_sent(
  self : QuicRecovery,
  space : PacketNumberSpace,
) -> Int64 {
  match space {
    Initial => self.largest_initial_sent
    Handshake => self.largest_handshake_sent
    Application => self.largest_application_sent
  }
}

///|
fn QuicRecovery::set_largest_sent(
  self : QuicRecovery,
  space : PacketNumberSpace,
  number : Int64,
) -> Unit {
  match space {
    Initial => self.largest_initial_sent = number
    Handshake => self.largest_handshake_sent = number
    Application => self.largest_application_sent = number
  }
}

///|
fn QuicRecovery::largest_acked(
  self : QuicRecovery,
  space : PacketNumberSpace,
) -> Int64 {
  match space {
    Initial => self.largest_initial_acked
    Handshake => self.largest_handshake_acked
    Application => self.largest_application_acked
  }
}

///|
fn QuicRecovery::set_largest_acked(
  self : QuicRecovery,
  space : PacketNumberSpace,
  number : Int64,
) -> Unit {
  match space {
    Initial => self.largest_initial_acked = number
    Handshake => self.largest_handshake_acked = number
    Application => self.largest_application_acked = number
  }
}

///|
fn QuicRecovery::sent_after_recovery_start(
  self : QuicRecovery,
  packet : QuicSentPacket,
) -> Bool {
  match self.recovery_end {
    None => true
    Some((initial, handshake, application)) => {
      let boundary = match packet.space {
        Initial => initial
        Handshake => handshake
        Application => application
      }
      packet.number > boundary
    }
  }
}

///|
pub fn QuicRecovery::can_send(
  self : QuicRecovery,
  bytes : Int,
  in_flight : Bool,
  congestion_exempt? : Bool = false,
) -> Result[Unit, QuicError] {
  if bytes <= 0 {
    return Err(InvalidPacket("packet size must be positive"))
  }
  let bytes64 = bytes.to_int64()
  if in_flight {
    if self.bytes_in_flight > QUIC_MAX_VARINT - bytes64 {
      return Err(VarIntOverflow)
    }
    if !congestion_exempt &&
      bytes64 > self.congestion_window - self.bytes_in_flight {
      return Err(FlowControl(0L, "congestion window exhausted"))
    }
  }
  Ok(())
}

///|
/// Returns the oldest ack-eliciting packet in a packet-number space as the
/// source for a PTO probe.  PTO does not declare the source packet lost: the
/// original packet remains tracked until it is ACKed or loss detection removes
/// it.  Keeping it tracked is required for correct bytes-in-flight accounting
/// when an ACK for the original arrives after the probe was sent.
pub fn QuicRecovery::oldest_probe_packet(
  self : QuicRecovery,
  space : PacketNumberSpace,
) -> QuicSentPacket? {
  let mut selected : QuicSentPacket? = None
  for packet in self.sent {
    if packet.space != space || !packet.ack_eliciting {
      continue
    }
    match selected {
      None => selected = Some(packet)
      Some(previous) if packet.sent_at_ms < previous.sent_at_ms =>
        selected = Some(packet)
      _ => ()
    }
  }
  selected
}

///|
/// Supply contains_padding for packets with explicit or builder-added PADDING.
/// Congestion uses their full wire size even when they do not elicit an ACK.
pub fn QuicRecovery::on_packet_sent(
  self : QuicRecovery,
  packet : QuicSentPacket,
  contains_padding? : Bool = false,
  congestion_exempt? : Bool = false,
) -> Result[Unit, QuicError] {
  let in_flight = packet.ack_eliciting || contains_padding
  self
  .check_sent(packet, in_flight, congestion_exempt)
  .map(_ => self.record_sent(packet, in_flight))
}

///|
fn QuicRecovery::check_sent(
  self : QuicRecovery,
  packet : QuicSentPacket,
  in_flight : Bool,
  congestion_exempt : Bool,
) -> Result[Unit, QuicError] {
  if packet.number < 0L ||
    packet.number > QUIC_MAX_VARINT ||
    packet.bytes <= 0 ||
    packet.sent_at_ms < 0L {
    return Err(InvalidPacket("invalid sent packet metadata"))
  }
  if packet.number <= self.largest_sent(packet.space) {
    return Err(InvalidPacket("packet numbers must increase within their space"))
  }
  if (in_flight || packet.retransmittable) &&
    self.sent.length() >= self.config.max_tracked_packets {
    return Err(
      LimitExceeded(
        "QUIC recovery packet queue",
        self.config.max_tracked_packets,
      ),
    )
  }
  self.can_send(packet.bytes, in_flight, congestion_exempt~)
}

///|
fn QuicRecovery::record_sent(
  self : QuicRecovery,
  packet : QuicSentPacket,
  in_flight : Bool,
) -> Unit {
  if in_flight || packet.retransmittable {
    self.sent.push(packet)
  } else if !self.sent.is_empty() {
    self.recent_untracked.set(
      self.timestamp_slot(packet.space, packet.number),
      packet,
    )
  }
  if in_flight && !packet.ack_eliciting {
    self.padded_non_eliciting.add((packet.space, packet.number))
  }
  if in_flight {
    self.bytes_in_flight += packet.bytes.to_int64()
  }
  self.set_largest_sent(packet.space, packet.number)
  if packet.ack_eliciting {
    let timer = self.timer(packet.space)
    timer.last_eliciting_ms = packet.sent_at_ms
    timer.outstanding_eliciting += 1
    if self.restart_idle_on_send {
      self.last_activity_ms = packet.sent_at_ms
      self.restart_idle_on_send = false
    }
  }
}

///|
fn QuicRecovery::timestamp_slot(
  self : QuicRecovery,
  space : PacketNumberSpace,
  number : Int64,
) -> (PacketNumberSpace, Int64) {
  (space, number % self.config.max_tracked_packets.min(4096).to_int64())
}

///|
/// Release a tracked packet once, whether it was ACKed, lost or discarded.
/// Returns whether it supplied congestion feedback.
fn QuicRecovery::remove_sent(self : QuicRecovery, index : Int) -> Bool {
  let packet = self.sent.remove(index)
  if packet.ack_eliciting {
    self.timer(packet.space).outstanding_eliciting -= 1
  }
  let in_flight = packet.ack_eliciting ||
    self.padded_non_eliciting.remove_and_check((packet.space, packet.number))
  if in_flight {
    self.bytes_in_flight -= packet.bytes.to_int64()
  }
  in_flight
}

///|
pub fn QuicRecovery::on_receive(
  self : QuicRecovery,
  now_ms : Int64,
) -> Result[Unit, QuicError] {
  if now_ms < 0L {
    return Err(InvalidPacket("recovery clock cannot be negative"))
  }
  self.last_activity_ms = now_ms
  self.restart_idle_on_send = true
  Ok(())
}

///|
pub fn QuicRecovery::on_ack(
  self : QuicRecovery,
  space : PacketNumberSpace,
  ack : AckFrame,
  now_ms : Int64,
  ack_delay_exponent? : Int = 3,
  reset_pto? : Bool = true,
  handshake_confirmed? : Bool = true,
) -> Result[Array[QuicRecoveryEvent], QuicError] {
  ack.validate() catch {
    error => return Err(error)
  }
  let events = []
  self
  .apply_ack(
    space,
    ack,
    now_ms,
    ack_delay_exponent~,
    reset_pto~,
    handshake_confirmed~,
    acknowledged=Some(events),
  )
  .map(_ => events)
}

///|
/// Public ACKs are checked by on_ack. The packet driver has already decoded
/// and checked each range before it advances recovery.
fn QuicRecovery::apply_ack(
  self : QuicRecovery,
  space : PacketNumberSpace,
  ack : AckFrame,
  now_ms : Int64,
  ack_delay_exponent~ : Int,
  reset_pto~ : Bool,
  handshake_confirmed~ : Bool,
  acknowledged? : Array[QuicRecoveryEvent]? = None,
) -> Result[Unit, QuicError] {
  if now_ms < 0L || ack_delay_exponent < 0 || ack_delay_exponent > 20 {
    return Err(InvalidFrame("invalid recovery ACK"))
  }
  let largest = ack.largest_acknowledged
  if largest > self.largest_sent(space) {
    return Err(Protocol(0x0aL, "ACK acknowledges an unsent packet"))
  }
  let mut rtt_packet : QuicSentPacket? = None
  if largest > self.largest_acked(space) {
    self.set_largest_acked(space, largest)
    let slot = self.timestamp_slot(space, largest)
    if self.recent_untracked.get(slot) is Some(packet) &&
      packet.number == largest &&
      packet.sent_at_ms <= now_ms {
      rtt_packet = Some(packet)
      self.recent_untracked.remove(slot)
    }
  }
  let previously_tracked = self.sent.length()
  let mut acked_eliciting = false
  let mut acknowledged_after_recovery_start = false
  let mut acknowledged_bytes : Int64 = 0L
  let mut index = self.sent.length() - 1
  while index >= 0 {
    let packet = self.sent[index]
    if packet.space == space && ack.covers(packet.number) {
      let in_flight = self.remove_sent(index)
      if in_flight && self.sent_after_recovery_start(packet) {
        acknowledged_after_recovery_start = true
        acknowledged_bytes += packet.bytes.to_int64()
      }
      acked_eliciting = acked_eliciting || packet.ack_eliciting
      if packet.number == largest && packet.sent_at_ms <= now_ms {
        rtt_packet = Some(packet)
      }
      if acknowledged is Some(events) {
        events.push(
          PacketAcknowledged(packet.number, packet.space, packet.bytes),
        )
      }
    }
    index -= 1
  }
  match rtt_packet {
    Some(packet) if acked_eliciting => {
      let raw_sample = (now_ms - packet.sent_at_ms).max(1L)
      let min_rtt = self.min_rtt_ms.map_or(raw_sample, fn(previous) {
        previous.min(raw_sample)
      })
      self.min_rtt_ms = Some(min_rtt)
      let delay_micros = if ack.ack_delay() >
        QUIC_MAX_VARINT >> ack_delay_exponent {
        QUIC_MAX_VARINT
      } else {
        ack.ack_delay() << ack_delay_exponent
      }
      let decoded_delay_ms = (delay_micros + 999L) / 1000L
      // Initial ACKs are not delayed. Before confirmation the peer can need
      // longer than max_ack_delay to process its handshake, so that parameter
      // only caps the adjustment once the handshake is confirmed.
      let delay_ms = if space == Initial {
        0L
      } else if handshake_confirmed {
        decoded_delay_ms.min(self.peer_max_ack_delay_ms)
      } else {
        decoded_delay_ms
      }
      let sample = if raw_sample - min_rtt >= delay_ms {
        raw_sample - delay_ms
      } else {
        raw_sample
      }
      self.latest_rtt_ms = Some(raw_sample)
      match (self.smoothed_rtt_ms, self.rttvar_ms) {
        (None, _) => {
          self.smoothed_rtt_ms = Some(sample)
          self.rttvar_ms = Some(sample / 2L)
        }
        (Some(smoothed), Some(variance)) => {
          let delta = (smoothed - sample).abs()
          self.rttvar_ms = Some(quic_rtt_average(variance, delta, 4L))
          self.smoothed_rtt_ms = Some(quic_rtt_average(smoothed, sample, 8L))
        }
        _ => ()
      }
    }
    _ => ()
  }
  if reset_pto && self.sent.length() < previously_tracked {
    self.pto_count = 0
    self.last_probe_ms = None
  }
  if self.in_recovery && acknowledged_after_recovery_start {
    self.in_recovery = false
  }
  self.last_activity_ms = now_ms
  self.restart_idle_on_send = true
  // Public callers may drive loss detection solely through poll after an ACK.
  self.timer(space).loss_at_ms = Some(now_ms)
  if acknowledged_bytes > 0L {
    if self.congestion_window < self.ssthresh {
      self.congestion_window = (self.congestion_window + acknowledged_bytes).min(
        QUIC_MAX_VARINT,
      )
    } else if self.congestion_window > 0L {
      let increment = (1200L * acknowledged_bytes / self.congestion_window).max(
        1L,
      )
      self.congestion_window = (self.congestion_window + increment).min(
        QUIC_MAX_VARINT,
      )
    }
  }
  Ok(())
}

///|
/// Floor of the weighted average without overflowing on long clock intervals.
fn quic_rtt_average(previous : Int64, sample : Int64, divisor : Int64) -> Int64 {
  let diff = sample - previous
  let rounded = diff / divisor
  previous + rounded - (if diff % divisor < 0L { 1L } else { 0L })
}

///|
/// Marks packets older than the RFC 9002 packet/time thresholds as lost and
/// applies one congestion response for the loss episode.
pub fn QuicRecovery::detect_loss(
  self : QuicRecovery,
  space : PacketNumberSpace,
  now_ms : Int64,
) -> Result[Array[QuicRecoveryEvent], QuicError] {
  if now_ms < 0L {
    return Err(InvalidPacket("recovery clock cannot be negative"))
  }
  let timer = self.timer(space)
  timer.loss_at_ms = None
  let largest = self.largest_acked(space)
  if largest < 0L {
    return Ok([])
  }
  let rtt = self.latest_rtt_ms.unwrap_or(self.config.initial_rtt_ms)
  let smoothed = self.smoothed_rtt_ms.unwrap_or(rtt)
  let base = smoothed.max(rtt)
  let time_threshold = quic_deadline_ms(base, base / 8L).max(1L)
  let events : Array[QuicRecoveryEvent] = []
  let mut lost_after_recovery_start = false
  let mut index = self.sent.length() - 1
  while index >= 0 {
    let packet = self.sent[index]
    if packet.space == space && packet.number <= largest {
      let due = quic_deadline_ms(packet.sent_at_ms, time_threshold)
      if largest - packet.number < 3L && now_ms < due {
        timer.loss_at_ms = Some(timer.loss_at_ms.unwrap_or(due).min(due))
        index -= 1
        continue
      }
      let in_flight = self.remove_sent(index)
      if in_flight && self.sent_after_recovery_start(packet) {
        lost_after_recovery_start = true
      }
      events.push(PacketLost(packet.number, packet.space, packet.bytes))
    }
    index -= 1
  }
  if lost_after_recovery_start && !self.in_recovery {
    self.ssthresh = (self.congestion_window / 2L).max(2L * 1200L)
    self.congestion_window = self.ssthresh
    self.in_recovery = true
    self.recovery_end = Some(
      (
        self.largest_initial_sent,
        self.largest_handshake_sent,
        self.largest_application_sent,
      ),
    )
  }
  Ok(events)
}
