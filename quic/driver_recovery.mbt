///|
/// Frame payload retained beside recovery metadata.  QUIC acknowledgements
/// identify packets, while retransmission needs the original frame sequence.
struct QuicRetransmission {
  space : PacketNumberSpace
  number : Int64
  endpoint : @types.Endpoint?
  frames : Array[QuicFrame]
  mut pending : Bool
}

///|
fn quic_frame_is_ack_eliciting(frame : QuicFrame) -> Bool {
  match frame {
    Ack(_) | Padding => false
    _ => true
  }
}

///|
fn quic_frame_is_retransmittable(frame : QuicFrame) -> Bool {
  match frame {
    Ack(_) | Padding | PathResponse(_) | Datagram(_) => false
    _ => true
  }
}

///|
fn quic_frames_are_retransmittable(frames : Array[QuicFrame]) -> Bool {
  frames.any(quic_frame_is_retransmittable)
}

///|
fn QuicDatagramDriver::take_retransmission(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
  number : Int64,
) -> Array[QuicFrame]? {
  let mut index = self.retransmissions.length() - 1
  while index >= 0 {
    let entry = self.retransmissions[index]
    if entry.space == space && entry.number == number {
      self.retransmissions.remove(index) |> ignore
      return Some(entry.frames)
    }
    index -= 1
  }
  None
}

///|
fn quic_ack_contains(ack : AckFrame, number : Int64) -> Bool {
  ack
  .ranges()
  .any(fn(range) { number >= range.smallest() && number <= range.largest() })
}

///|
fn QuicDatagramDriver::mark_retransmission_pending(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
  number : Int64,
) -> Unit {
  for entry in self.retransmissions {
    if entry.space == space && entry.number == number {
      entry.pending = true
      return
    }
  }
}

///|
fn QuicDatagramDriver::next_pending_retransmission(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
) -> (Int64, Array[QuicFrame], @types.Endpoint)? {
  for entry in self.retransmissions {
    if entry.space == space && entry.pending {
      let endpoint = match entry.endpoint {
        Some(value) => value
        None => self.path.active()
      }
      return Some((entry.number, entry.frames, endpoint))
    }
  }
  None
}

///|
/// Finds retained frames for a packet without changing their pending state.
/// PTO uses this to build a new packet while leaving the source packet in the
/// recovery engine until its own ACK or loss notification arrives.
fn QuicDatagramDriver::retransmission_for_number(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
  number : Int64,
) -> (Array[QuicFrame], @types.Endpoint)? {
  for entry in self.retransmissions {
    if entry.space == space && entry.number == number {
      let endpoint = match entry.endpoint {
        Some(value) => value
        None => self.path.active()
      }
      return Some((entry.frames, endpoint))
    }
  }
  None
}

///|
fn QuicDatagramDriver::flush_pending_retransmissions(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
  now_ms : Int64,
  congestion_exempt? : Bool = false,
) -> Result[Array[QuicDriverAction], QuicError] {
  let actions : Array[QuicDriverAction] = []
  while self.next_pending_retransmission(space)
        is Some((number, frames, endpoint)) {
    match
      self.send_frames_internal_to(
        space,
        frames,
        now_ms,
        congestion_exempt,
        Some(number),
        endpoint,
      ) {
      Ok(action) => actions.push(action)
      // Congestion backpressure is not a protocol failure. The retained entry
      // remains pending and can be sent after a later ACK or timer tick.
      Err(FlowControl(0L, _)) => break
      Err(AmplificationBlocked) => break
      Err(error) => return Err(error)
    }
  }
  Ok(actions)
}

///|
/// Applies recovery notifications to the driver's retained frame payloads.
/// ACKed payloads are discarded and lost payloads are marked pending. They are
/// removed only after a replacement packet has been accepted by recovery.
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
  let events = match
    self.recovery.on_ack(
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
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if space != Initial &&
    events.any(fn(event) { event is PacketAcknowledged(_, _, _) }) {
    self.peer_address_validated = true
  }
  let lost = match self.recovery.detect_loss(space, now_ms) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if space == Application {
    for event in events {
      if event is PacketAcknowledged(number, _, _) {
        self.key_update.confirmed = true
        if number >= self.key_update.send_phase_start {
          self.key_update.send_phase_acked = true
        }
      }
    }
    if self.key_update.confirmed {
      self.discard_packet_space(Handshake)
    }
  }
  // A late ACK can arrive after a packet was declared lost but before its
  // retained frames could be retransmitted. Remove every acknowledged copy,
  // not only packets still present in the recovery engine.
  let mut retained_index = self.retransmissions.length() - 1
  while retained_index >= 0 {
    let entry = self.retransmissions[retained_index]
    if entry.space == space && quic_ack_contains(ack, entry.number) {
      self.retransmissions.remove(retained_index) |> ignore
    }
    retained_index -= 1
  }
  for event in lost {
    match event {
      PacketLost(number, event_space, bytes) => {
        ignore(bytes)
        self.mark_retransmission_pending(event_space, number)
      }
      _ => ()
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
  if quic_frames_are_retransmittable(frames) {
    let retained : Array[QuicFrame] = []
    for frame in frames {
      if quic_frame_is_retransmittable(frame) {
        retained.push(frame)
      }
    }
    self.retransmissions.push({
      space,
      number,
      endpoint: if frames.any(fn(frame) { frame is PathChallenge(_) }) {
        Some(endpoint)
      } else {
        None
      },
      frames: retained,
      pending: false,
    })
  }
}
