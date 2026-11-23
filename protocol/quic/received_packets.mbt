///|
/// Descending ranges serve both replay detection and ACK generation. Only
/// packet numbers within 4096 of the largest received are retained.
priv struct QuicReceivedPackets {
  ranges : Array[AckRange]
  mut largest_at_ms : Int64
  mut pending : (Int64, Int64)?
}

///|
fn QuicReceivedPackets::new() -> QuicReceivedPackets {
  { ranges: [], largest_at_ms: 0L, pending: None, }
}

///|
fn QuicReceivedPackets::largest(self : QuicReceivedPackets) -> Int64 {
  if self.ranges.is_empty() {
    -1L
  } else {
    self.ranges[0].largest
  }
}

///|
fn QuicReceivedPackets::seen(
  self : QuicReceivedPackets,
  number : Int64,
) -> Bool {
  if number <= self.largest() - 4096L {
    return true
  }
  for range in self.ranges {
    if number > range.largest {
      return false
    }
    if number >= range.smallest {
      return true
    }
  }
  false
}

///|
/// Called once for an authenticated, previously unseen packet.
fn QuicReceivedPackets::record(
  self : QuicReceivedPackets,
  number : Int64,
  now_ms : Int64,
) -> Unit {
  if number > self.largest() {
    self.largest_at_ms = now_ms
  }
  let mut i = 0
  while i < self.ranges.length() && self.ranges[i].smallest > number + 1L {
    i += 1
  }
  let mut range : AckRange = { largest: number, smallest: number, }
  if i < self.ranges.length() && self.ranges[i].largest >= number - 1L {
    let current = self.ranges[i]
    range = {
      largest: current.largest.max(number),
      smallest: current.smallest.min(number),
    }
    if i + 1 < self.ranges.length() &&
      self.ranges[i + 1].largest == range.smallest - 1L {
      range = { ..range, smallest: self.ranges.remove(i + 1).smallest, }
    }
    self.ranges[i] = range
  } else {
    self.ranges.insert(i, range)
  }
  let floor = self.largest() - 4095L
  while self.ranges.last() is Some(last) && last.largest < floor {
    ignore(self.ranges.pop())
  }
  let last = self.ranges.length() - 1
  if self.ranges[last].smallest < floor {
    self.ranges[last] = { ..self.ranges[last], smallest: floor, }
  }
}

///|
/// Keep recent ranges and include the triggering packet when it arrived out
/// of order. Each gap and range in this window uses at most two varint bytes.
fn QuicReceivedPackets::pending_ack(
  self : QuicReceivedPackets,
  space : PacketNumberSpace,
  limits : QuicLimits,
  now_ms : Int64,
) -> QuicFrame? {
  guard self.pending is Some((trigger, trigger_at_ms)) else { return None }
  let head = self.ranges[0]
  // The local transport parameters advertise the default delay exponent of 3.
  let delay_since = fn(received_at_ms) {
    if space == Application {
      (now_ms - received_at_ms).max(0L).min(QUIC_MAX_VARINT / 125L) * 125L
    } else {
      0L
    }
  }
  let delay = delay_since(self.largest_at_ms)
  let base_size = 2 +
    quic_encoded_varint_size(head.largest) +
    quic_encoded_varint_size(delay) +
    quic_encoded_varint_size(head.largest - head.smallest)
  let extra = limits.max_ack_ranges
    .min((limits.max_frame_payload - base_size).max(0) / 4)
    .min(15)
  let ranges = self.ranges[:(extra + 1).min(self.ranges.length())].to_owned()
  let mut ack_delay = delay
  if trigger < ranges[ranges.length() - 1].smallest &&
    trigger > self.largest() - 4096L {
    if ranges.length() == 1 {
      // The budget admits one range. Acknowledge the triggering packet now.
      ranges[0] = { largest: trigger, smallest: trigger, }
      ack_delay = delay_since(trigger_at_ms)
    } else {
      for i in ranges.length()..<self.ranges.length() {
        let range = self.ranges[i]
        if trigger >= range.smallest {
          ranges[ranges.length() - 1] = range
          break
        }
      }
    }
  }
  Some(
    Ack({
      largest_acknowledged: ranges[0].largest,
      ack_delay,
      ranges,
      ecn_counts: None,
    }),
  )
}

///|
fn QuicDatagramDriver::received(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
) -> QuicReceivedPackets {
  match space {
    Initial => self.received_initial
    Handshake => self.received_handshake
    Application => self.received_application
  }
}
