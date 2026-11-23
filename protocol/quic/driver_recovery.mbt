///|
/// Frame payload retained beside recovery metadata.  QUIC acknowledgements
/// identify packets, while retransmission needs the original frame sequence.
struct QuicRetransmission {
  space : PacketNumberSpace
  live : Array[Int64]
  mut first : Int64?
  mut last_lost : Int64?
  endpoint : @types.Endpoint?
  frames : Array[QuicFrame]
}

///|
priv enum QuicSendMode {
  Regular
  Retransmit(QuicRetransmission)
  Probe(QuicRetransmission?)
}

///|
fn QuicRetransmission::acknowledged(
  self : QuicRetransmission,
  ack : AckFrame,
) -> Bool {
  (self.first is Some(number) && ack.covers(number)) ||
  (self.last_lost is Some(number) && ack.covers(number)) ||
  self.live.any(number => ack.covers(number))
}

///|
fn quic_frame_is_ack_eliciting(frame : QuicFrame) -> Bool {
  match frame {
    Ack(_) | Padding | ConnectionClose(_, _, _, _) => false
    _ => true
  }
}

///|
fn quic_frame_is_retransmittable(frame : QuicFrame) -> Bool {
  match frame {
    Ack(_)
    | Ping
    | Padding
    | ConnectionClose(_, _, _, _)
    | PathResponse(_)
    | Datagram(_) => false
    _ => true
  }
}

///|
/// Drop superseded stream data or CID announcements from retransmission. Leave
/// packet numbers in recovery for congestion accounting and preserve any other
/// retransmittable frames that shared those packets.
fn QuicDatagramDriver::discard_application_retransmissions(
  self : QuicDatagramDriver,
  discard : (QuicFrame) -> Bool,
) -> Unit {
  self.retransmissions.retain(entry => {
    if entry.space == Application {
      entry.frames.retain(frame => !discard(frame))
    }
    !entry.frames.is_empty()
  })
}

///|
fn AckFrame::covers(self : AckFrame, number : Int64) -> Bool {
  self.ranges.any(range => number >= range.smallest && number <= range.largest)
}

///|
fn QuicDatagramDriver::note_retransmission_loss(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
  number : Int64,
) -> Unit {
  if self.retransmission_for_number(space, number) is Some(entry) {
    entry.live.retain(copy => copy != number)
    entry.last_lost = Some(entry.last_lost.unwrap_or(number).max(number))
  }
}

///|
fn QuicDatagramDriver::next_pending_retransmission(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
) -> QuicRetransmission? {
  for entry in self.retransmissions {
    if entry.space == space && entry.live.is_empty() {
      return Some(entry)
    }
  }
  None
}

///|
fn QuicDatagramDriver::retransmission_for_number(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
  number : Int64,
) -> QuicRetransmission? {
  for entry in self.retransmissions {
    if entry.space == space && entry.live.contains(number) {
      return Some(entry)
    }
  }
  None
}

///|
/// Reuse the oldest outstanding payload when available. Each copy keeps its
/// own recovery metadata until acknowledged, lost or discarded with its keys.
fn QuicDatagramDriver::send_probe(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
  now_ms : Int64,
) -> Result[QuicDriverAction, QuicError] {
  let entry = self.retransmissions
    .iter()
    .find_first(entry => entry.space == space)
  let (frames, destination) = match entry {
    Some(payload) =>
      (payload.frames, payload.endpoint.unwrap_or(self.path.active()))
    None => ([Ping], self.path.active())
  }
  self.send_frames_internal_to(space, frames, now_ms, Probe(entry), destination)
}

///|
fn QuicDatagramDriver::flush_pending_retransmissions(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
  now_ms : Int64,
) -> Result[Array[QuicDriverAction], QuicError] {
  let actions : Array[QuicDriverAction] = []
  while self.next_pending_retransmission(space) is Some(entry) {
    match
      self.send_frames_internal_to(
        space,
        entry.frames,
        now_ms,
        Retransmit(entry),
        entry.endpoint.unwrap_or(self.path.active()),
      ) {
      Ok(action) => actions.push(action)
      Err(error) if error.send_blocked() => break
      Err(error) => return Err(error)
    }
  }
  Ok(actions)
}

///|
/// Applies recovery notifications to the driver's retained frame payloads.
/// An ACK releases the shared payload once. A loss schedules retransmission
/// only after recovery has lost every outstanding copy.
fn QuicDatagramDriver::apply_recovery_ack(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
  ack : AckFrame,
  now_ms : Int64,
) -> Result[Unit, QuicError] {
  let exponent = match self.peer_parameters {
    Some(params) => params.ack_delay_exponent
    None => 3
  }
  match
    self.recovery.apply_ack(
      space,
      ack,
      now_ms,
      ack_delay_exponent=exponent,
      reset_pto=self.role == Server ||
        space != Initial ||
        self.peer_address_validated ||
        self.key_update.confirmed,
      handshake_confirmed=self.key_update.confirmed,
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  // A valid ACK proves the peer processed this encryption level even when
  // the referenced packet no longer needs congestion or retransmission state.
  if space != Initial {
    self.peer_address_validated = true
  }
  let lost = match self.recovery.detect_loss(space, now_ms) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if space == Application {
    self.key_update.confirmed = true
    if ack.largest_acknowledged >= self.key_update.send_phase_start {
      self.key_update.send_phase_acked = true
    }
    self.discard_packet_space(Handshake)
  }
  // A late ACK can arrive after a packet was declared lost but before its
  // retained frames could be retransmitted. Remove every acknowledged copy,
  // not only packets still present in the recovery engine.
  let mut retained_index = self.retransmissions.length() - 1
  while retained_index >= 0 {
    let entry = self.retransmissions[retained_index]
    if entry.space == space && entry.acknowledged(ack) {
      for frame in entry.frames {
        // Raw send_frames can also carry frames outside connection-owned streams.
        ignore(self.connection.acknowledge_stream_frame(frame))
      }
      self.retransmissions.remove(retained_index) |> ignore
    }
    retained_index -= 1
  }
  for event in lost {
    if event is PacketLost(number, event_space, _) {
      self.note_retransmission_loss(event_space, number)
    }
  }
  Ok(())
}

///|
fn QuicDatagramDriver::queue_retransmission(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
  number : Int64,
  endpoint : @types.Endpoint,
  frames : Array[QuicFrame],
) -> Unit {
  self.retransmissions.push({
    space,
    first: Some(number),
    last_lost: None,
    live: [number],
    endpoint: if frames.any(fn(frame) { frame is PathChallenge(_) }) {
      Some(endpoint)
    } else {
      None
    },
    frames: frames.filter(quic_frame_is_retransmittable),
  })
}

///|
fn QuicDatagramDriver::discard_stream_retransmissions(
  self : QuicDatagramDriver,
  id : Int64,
) -> Unit {
  self.discard_application_retransmissions(frame => {
    frame is Stream(data) && data.stream_id == id
  })
}
