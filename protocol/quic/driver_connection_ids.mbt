///|
fn QuicDatagramDriver::receive_peer_connection_id(
  self : QuicDatagramDriver,
  sequence : Int64,
  retire_prior_to : Int64,
  id : ConnectionId,
  token : Bytes,
) -> Result[Unit, QuicError] {
  let update = match
    self.peer_connection_ids.prepare_announcement(
      sequence, retire_prior_to, id, token,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let additional : Array[Int64] = []
  for retired in update.retirements {
    if !self.pending_retirements.contains(retired) {
      additional.push(retired)
    }
  }
  if additional.length() >
    self.max_retransmissions - self.pending_retirements.length() {
    return Err(
      LimitExceeded("pending CID retirements", self.max_retransmissions),
    )
  }
  self.peer_connection_ids.apply_update(update)
  self.pending_retirements.append(additional)
  let active = self.peer_connection_ids.active()
  if !active.any(fn(value) { value.id == self.peer_connection_id }) {
    self.peer_connection_id = active[0].id
  }
  Ok(())
}

///|
/// Keep required retirements until packet recovery accepts them. Reserve the
/// existing response payload and a maximum-width short header before adding
/// a bounded batch of frames.
fn QuicDatagramDriver::append_pending_retirements(
  self : QuicDatagramDriver,
  frames : Array[QuicFrame],
) -> Int {
  if self.pending_retirements.is_empty() {
    return 0
  }
  let payload_size = match quic_encode_frames(frames, limits=self.limits) {
    Ok(payload) => payload.length()
    // The normal send path reports the original response encoding error.
    Err(_) => return 0
  }
  let header_size = 1 + self.peer_connection_id.bytes().length() + 4 + 16
  let payload_limit = (self.send_datagram_limit() - header_size).min(
    self.limits.max_frame_payload,
  )
  let mut available = (payload_limit - payload_size).max(0)
  let mut count = 0
  while count < self.pending_retirements.length().min(64) {
    let sequence = self.pending_retirements[count]
    let size = 1 + QuicVarInt::new(sequence).unwrap().encoded_length()
    if size > available {
      break
    }
    frames.push(RetireConnectionId(sequence))
    available -= size
    count += 1
  }
  count
}

///|
fn QuicDatagramDriver::consume_pending_retirements(
  self : QuicDatagramDriver,
  count : Int,
) -> Unit {
  for _ in 0..<count {
    self.pending_retirements.remove(0) |> ignore
  }
}

///|
fn QuicDatagramDriver::flush_retirements(
  self : QuicDatagramDriver,
  now_ms : Int64,
) -> Result[Array[QuicDriverAction], QuicError] {
  let actions : Array[QuicDriverAction] = []
  if self.state() != Established {
    return Ok(actions)
  }
  while !self.pending_retirements.is_empty() {
    let frames : Array[QuicFrame] = []
    let count = self.append_pending_retirements(frames)
    if count == 0 {
      break
    }
    match self.send_frames(Application, frames, now_ms) {
      Ok(action) => {
        self.consume_pending_retirements(count)
        actions.push(action)
      }
      Err(AmplificationBlocked) | Err(FlowControl(0L, _)) => break
      Err(LimitExceeded("QUIC retransmission queue", _)) => break
      Err(LimitExceeded("QUIC recovery packet queue", _)) => break
      Err(error) => return Err(error)
    }
  }
  Ok(actions)
}
