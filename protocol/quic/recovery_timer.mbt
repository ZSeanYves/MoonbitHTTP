///|
let quic_number_spaces : ReadOnlyArray[PacketNumberSpace] = [
  Initial,
  Handshake,
  Application,
]

///|
#derive(Debug)
priv struct QuicSpaceTimer {
  mut last_eliciting_ms : Int64
  mut outstanding_eliciting : Int32
  mut loss_at_ms : Int64?
}

///|
fn QuicSpaceTimer::new() -> QuicSpaceTimer {
  { last_eliciting_ms: 0L, outstanding_eliciting: 0, loss_at_ms: None, }
}

///|
fn QuicRecovery::timer(
  self : QuicRecovery,
  space : PacketNumberSpace,
) -> QuicSpaceTimer {
  match space {
    Initial => self.timers.0
    Handshake => self.timers.1
    Application => self.timers.2
  }
}

///|
fn QuicRecovery::recovery_pto(
  self : QuicRecovery,
  space : PacketNumberSpace,
) -> Int64 {
  let smoothed = self.smoothed_rtt_ms.unwrap_or(self.config.initial_rtt_ms)
  let variance = self.rttvar_ms.unwrap_or(self.config.initial_rtt_ms / 2L)
  let max_ack_delay = if space == Application {
    self.peer_max_ack_delay_ms
  } else {
    0L
  }
  let spread = if variance > @int64.MAX_VALUE / 4L {
    @int64.MAX_VALUE
  } else {
    (4L * variance).max(1L)
  }
  quic_deadline_ms(quic_deadline_ms(smoothed, spread), max_ack_delay).min(
    self.config.max_pto_ms,
  )
}

///|
fn pto_backoff(base : Int64, count : Int32, limit : Int64) -> Int64 {
  if base > limit >> count {
    limit
  } else {
    base << count
  }
}

///|
pub fn QuicRecovery::poll(
  self : QuicRecovery,
  now_ms : Int64,
  application_confirmed~ : Bool = true,
) -> Result[Array[QuicRecoveryEvent], QuicError] {
  self
  .timer_events(now_ms, application_confirmed, None)
  .map(events => {
    if events is [ProbeTimeout(space)] {
      self.probe_sent(space, now_ms)
    }
    events
  })
}

///|
fn QuicRecovery::probe_sent(
  self : QuicRecovery,
  space : PacketNumberSpace,
  now_ms : Int64,
) -> Unit {
  self.timer(space).last_eliciting_ms = now_ms
  self.pto_count = self.pto_count.min(61) + 1
  self.last_probe_ms = Some(now_ms)
}

///|
/// Elapsed time uses the caller's monotonic clock and its full Int64 range.
fn quic_deadline_ms(
  start : Int64,
  duration : Int64,
  periods~ : Int64 = 1L,
) -> Int64 {
  if duration > (@int64.MAX_VALUE - start) / periods {
    @int64.MAX_VALUE
  } else {
    start + duration * periods
  }
}

///|
fn QuicRecovery::probe_deadline(
  self : QuicRecovery,
  space : PacketNumberSpace,
  last_send_ms : Int64,
) -> Int64 {
  let timeout = pto_backoff(
    self.recovery_pto(space),
    self.pto_count,
    self.config.max_pto_ms,
  )
  quic_deadline_ms(last_send_ms, timeout)
}

///|
fn QuicRecovery::idle_deadline(
  self : QuicRecovery,
  application_confirmed : Bool,
) -> Int64? {
  let idle_ms = match self.negotiated_idle_ms {
    None => self.config.idle_timeout_ms
    Some(0L) => 0L
    Some(timeout) => {
      let base = self.recovery_pto(
        if application_confirmed {
          Application
        } else {
          Handshake
        },
      )
      timeout.max(quic_deadline_ms(0L, base, periods=3L))
    }
  }
  if idle_ms > 0L {
    Some(quic_deadline_ms(self.last_activity_ms, idle_ms))
  } else {
    None
  }
}

///|
fn QuicRecovery::next_loss_deadline(self : QuicRecovery) -> Int64? {
  let mut next = None
  for space in quic_number_spaces {
    if self.timer(space).loss_at_ms is Some(deadline) &&
      !(next is Some(earlier) && earlier <= deadline) {
      next = Some(deadline)
    }
  }
  next
}

///|
fn QuicRecovery::next_probe_deadline(
  self : QuicRecovery,
  application_confirmed : Bool,
  validation_space : PacketNumberSpace?,
) -> (PacketNumberSpace, Int64)? {
  let mut next_probe : (PacketNumberSpace, Int64)? = None
  for space in quic_number_spaces {
    let timer = self.timer(space)
    if timer.outstanding_eliciting > 0 &&
      (space != Application || application_confirmed) {
      let deadline = self.probe_deadline(space, timer.last_eliciting_ms)
      if next_probe is None ||
        (next_probe is Some((_, previous)) && deadline < previous) {
        next_probe = Some((space, deadline))
      }
    }
  }
  if next_probe is None && validation_space is Some(space) {
    next_probe = Some(
      (
        space,
        self.probe_deadline(
          space,
          self.last_activity_ms.max(self.timer(space).last_eliciting_ms),
        ),
      ),
    )
  }
  next_probe
}

///|
/// A pending loss timer takes precedence over any PTO. Backoff is committed by
/// the packet driver only after a probe has passed recovery and path admission.
fn QuicRecovery::timer_events(
  self : QuicRecovery,
  now_ms : Int64,
  application_confirmed : Bool,
  validation_space : PacketNumberSpace?,
) -> Result[Array[QuicRecoveryEvent], QuicError] {
  if now_ms < 0L {
    return Err(InvalidPacket("recovery clock cannot be negative"))
  }
  if self.idle_deadline(application_confirmed) is Some(idle) && now_ms >= idle {
    return Ok([IdleTimeout])
  }
  let events : Array[QuicRecoveryEvent] = []
  if self.next_loss_deadline() is Some(loss) {
    if now_ms >= loss {
      for space in quic_number_spaces {
        if self.timer(space).loss_at_ms is Some(time) && now_ms >= time {
          match self.detect_loss(space, now_ms) {
            Ok(lost) => events.append(lost)
            Err(error) => return Err(error)
          }
        }
      }
    }
    if !events.is_empty() || self.next_loss_deadline() is Some(_) {
      return Ok(events)
    }
  }
  let next_probe = self.next_probe_deadline(
    application_confirmed, validation_space,
  )
  if next_probe is Some((space, deadline)) &&
    now_ms >= deadline &&
    self.last_probe_ms != Some(now_ms) {
    events.push(ProbeTimeout(space))
  }
  Ok(events)
}
