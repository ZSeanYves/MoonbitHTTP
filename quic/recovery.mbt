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
  sent : Array[QuicSentPacket]
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
    sent: [],
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
pub fn QuicRecovery::can_send(
  self : QuicRecovery,
  bytes : Int,
  ack_eliciting : Bool,
  congestion_exempt? : Bool = false,
) -> Result[Unit, QuicError] {
  if bytes <= 0 {
    return Err(InvalidPacket("packet size must be positive"))
  }
  let bytes64 = bytes.to_int64()
  if ack_eliciting {
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
/// Removes the oldest ack-eliciting packet in a packet-number space when a
/// probe timeout is acted upon.  The driver uses the returned number to pair
/// recovery state with the frame payload it retained for retransmission.
pub fn QuicRecovery::take_oldest_probe_packet(
  self : QuicRecovery,
  space : PacketNumberSpace,
) -> QuicSentPacket? {
  let mut selected : (Int, QuicSentPacket)? = None
  for index, packet in self.sent {
    if packet.space != space || !packet.ack_eliciting {
      continue
    }
    match selected {
      None => selected = Some((index, packet))
      Some((_, previous)) if packet.sent_at_ms < previous.sent_at_ms =>
        selected = Some((index, packet))
      _ => ()
    }
  }
  match selected {
    None => None
    Some((index, packet)) => {
      if packet.ack_eliciting {
        self.bytes_in_flight = (self.bytes_in_flight - packet.bytes.to_int64()).max(
          0L,
        )
      }
      self.sent.remove(index) |> ignore
      Some(packet)
    }
  }
}

///|
fn recovery_packet_matches(
  packet : QuicSentPacket,
  space : PacketNumberSpace,
  ranges : Array[AckRange],
) -> Bool {
  if packet.space != space {
    return false
  }
  for range in ranges {
    if packet.number >= range.smallest && packet.number <= range.largest {
      return true
    }
  }
  false
}

///|
fn QuicRecovery::recovery_pto(self : QuicRecovery) -> Int64 {
  let smoothed = self.smoothed_rtt_ms.unwrap_or(self.config.initial_rtt_ms)
  let variance = self.rttvar_ms.unwrap_or(self.config.initial_rtt_ms / 2L)
  let granularity = 1L
  let base = smoothed +
    (4L * variance).max(granularity) +
    self.config.max_ack_delay_ms
  base.min(self.config.max_pto_ms).max(1L)
}

///|
pub fn QuicRecovery::on_packet_sent(
  self : QuicRecovery,
  packet : QuicSentPacket,
  congestion_exempt? : Bool = false,
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
  let tracked = packet.ack_eliciting || packet.retransmittable
  if tracked && self.sent.length() >= self.config.max_tracked_packets {
    return Err(
      LimitExceeded(
        "QUIC recovery packet queue",
        self.config.max_tracked_packets,
      ),
    )
  }
  match self.can_send(packet.bytes, packet.ack_eliciting, congestion_exempt~) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if tracked {
    self.sent.push(packet)
  }
  if packet.ack_eliciting {
    self.bytes_in_flight += packet.bytes.to_int64()
  }
  self.set_largest_sent(packet.space, packet.number)
  self.last_activity_ms = packet.sent_at_ms
  Ok(())
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
  self.pto_count = 0
  self.last_probe_ms = None
  Ok(())
}

///|
pub fn QuicRecovery::on_ack(
  self : QuicRecovery,
  space : PacketNumberSpace,
  ack : AckFrame,
  now_ms : Int64,
  ack_delay_exponent? : Int = 3,
) -> Result[Array[QuicRecoveryEvent], QuicError] {
  let ranges = ack.ranges()
  if ranges.is_empty() ||
    now_ms < 0L ||
    ack_delay_exponent < 0 ||
    ack_delay_exponent > 20 {
    return Err(InvalidFrame("invalid recovery ACK"))
  }
  if ranges[0].largest != ack.largest_acknowledged() ||
    ack.largest_acknowledged() > self.largest_sent(space) {
    return Err(Protocol(0x0aL, "ACK acknowledges an unsent packet"))
  }
  let mut previous_smallest = ack.largest_acknowledged() + 1L
  for range in ranges {
    if range.smallest < 0L ||
      range.largest < range.smallest ||
      range.largest >= previous_smallest {
      return Err(InvalidFrame("ACK ranges overlap or are unordered"))
    }
    previous_smallest = range.smallest
  }
  let largest = ack.largest_acknowledged()
  if largest > self.largest_acked(space) {
    self.set_largest_acked(space, largest)
  }
  let events : Array[QuicRecoveryEvent] = []
  let mut rtt_packet : QuicSentPacket? = None
  let mut index = self.sent.length() - 1
  while index >= 0 {
    let packet = self.sent[index]
    if recovery_packet_matches(packet, space, ranges) {
      if packet.ack_eliciting {
        self.bytes_in_flight = (self.bytes_in_flight - packet.bytes.to_int64()).max(
          0L,
        )
      }
      if packet.number == largest &&
        packet.ack_eliciting &&
        packet.sent_at_ms <= now_ms {
        rtt_packet = Some(packet)
      }
      events.push(PacketAcknowledged(packet.number, packet.space, packet.bytes))
      self.sent.remove(index) |> ignore
    }
    index -= 1
  }
  match rtt_packet {
    Some(packet) => {
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
      let delay_ms = ((delay_micros + 999L) / 1000L).min(
        self.config.max_ack_delay_ms,
      )
      let sample = if space == Application && raw_sample > min_rtt + delay_ms {
        raw_sample - delay_ms
      } else {
        raw_sample
      }
      self.latest_rtt_ms = Some(sample)
      match (self.smoothed_rtt_ms, self.rttvar_ms) {
        (None, _) => {
          self.smoothed_rtt_ms = Some(sample)
          self.rttvar_ms = Some(sample / 2L)
        }
        (Some(smoothed), Some(variance)) => {
          let delta = (smoothed - sample).abs()
          self.rttvar_ms = Some((3L * variance + delta) / 4L)
          self.smoothed_rtt_ms = Some((7L * smoothed + sample) / 8L)
        }
        _ => ()
      }
    }
    None => ()
  }
  if events.any(fn(event) { event is PacketAcknowledged(_, _, _) }) {
    self.pto_count = 0
    self.last_probe_ms = None
  }
  self.last_activity_ms = now_ms
  if !events.is_empty() {
    let acknowledged_bytes : Int64 = for event in events; total = 0L {
      continue match event {
          PacketAcknowledged(_, _, bytes) => total + bytes.to_int64()
          _ => total
        }
    } nobreak {
      total
    }
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
  Ok(events)
}

///|
pub fn QuicRecovery::poll(
  self : QuicRecovery,
  now_ms : Int64,
) -> Result[Array[QuicRecoveryEvent], QuicError] {
  if now_ms < 0L {
    return Err(InvalidPacket("recovery clock cannot be negative"))
  }
  if now_ms - self.last_activity_ms >= self.config.idle_timeout_ms {
    return Ok([IdleTimeout])
  }
  let oldest : QuicSentPacket? = for packet in self.sent; result = None {
    if !packet.ack_eliciting {
      continue result
    }
    match result {
      None => continue Some(packet)
      Some(previous) if packet.sent_at_ms < previous.sent_at_ms =>
        continue Some(packet)
      _ => continue result
    }
  } nobreak {
    result
  }
  match oldest {
    None => Ok([])
    Some(packet) => {
      let deadline = packet.sent_at_ms +
        self.recovery_pto() * (self.pto_count.to_int64() + 1L)
      if now_ms >= deadline && self.last_probe_ms != Some(deadline) {
        self.pto_count += 1
        self.last_probe_ms = Some(deadline)
        Ok([ProbeTimeout(packet.space)])
      } else {
        Ok([])
      }
    }
  }
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
  let largest = self.largest_acked(space)
  if largest < 0L {
    return Ok([])
  }
  let rtt = self.latest_rtt_ms.unwrap_or(self.config.initial_rtt_ms)
  let smoothed = self.smoothed_rtt_ms.unwrap_or(rtt)
  let time_threshold = (smoothed.max(rtt) * 9L / 8L).max(1L)
  let events : Array[QuicRecoveryEvent] = []
  let mut index = self.sent.length() - 1
  while index >= 0 {
    let packet = self.sent[index]
    if packet.space == space &&
      (
        packet.number + 3L <= largest ||
        packet.sent_at_ms + time_threshold <= now_ms
      ) {
      if packet.ack_eliciting {
        self.bytes_in_flight = (self.bytes_in_flight - packet.bytes.to_int64()).max(
          0L,
        )
      }
      events.push(PacketLost(packet.number, packet.space, packet.bytes))
      self.sent.remove(index) |> ignore
    }
    index -= 1
  }
  if !events.is_empty() && !self.in_recovery {
    self.ssthresh = (self.congestion_window / 2L).max(2L * 1200L)
    self.congestion_window = self.ssthresh
    self.in_recovery = true
  }
  if events.is_empty() {
    self.in_recovery = false
  }
  Ok(events)
}
