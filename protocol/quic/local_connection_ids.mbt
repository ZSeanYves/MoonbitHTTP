///|
priv struct LocalConnectionIds {
  entropy : &@transport.Entropy
  reserve : (ConnectionId) -> Bool
  release : (ConnectionId) -> Unit
  max_issued : Int
  issued : Set[Bytes]
  tokens : Set[Bytes]
  // In sequence order. Both routing and peer admission need at most two.
  active : Array[QuicConnectionId]
  mut pending : QuicConnectionId?
  mut floor : Int64
  mut rotate_from : Int64?
}

///|
/// Supply a spare local CID after authentication and replace peer-retired IDs.
/// A shared socket must reserve each new route before advertisement and release
/// it on retirement or send failure. The socket owner clears its remaining
/// routes on close. The initial route is already owned by the caller.
/// max_issued includes the initial CID and bounds lifetime uniqueness history.
pub fn[E : @transport.Entropy] QuicDatagramDriver::enable_connection_id_issuance(
  self : QuicDatagramDriver,
  entropy : E,
  reserve? : (ConnectionId) -> Bool = _ => true,
  release? : (ConnectionId) -> Unit = _ => (),
  max_issued? : Int = 256,
) -> Result[Unit, QuicError] {
  let initial = self.local_connection_id
  if initial.bytes().is_empty() || self.local_ids is Some(_) {
    return Err(
      InvalidPacket(
        "local CID issuance requires a nonempty initial ID and a single issuer",
      ),
    )
  }
  if max_issued < 2 {
    return Err(LimitExceeded("local CID lifetime budget", max_issued))
  }
  self.local_ids = Some({
    entropy,
    reserve,
    release,
    max_issued,
    issued: Set([initial.bytes()]),
    tokens: Set([]),
    active: [{ sequence: 0L, id: initial, reset_token: b"", retired: false, }],
    pending: None,
    floor: 0L,
    rotate_from: None,
  })
  Ok(())
}

///|
/// Ask the peer to move to the newest local CID. Transmit the returned datagrams.
/// Poll retries a blocked announcement. The old route stays active until peer retirement.
/// Repeated calls while the same retirement is outstanding coalesce.
pub fn QuicDatagramDriver::rotate_local_connection_id(
  self : QuicDatagramDriver,
  now_ms : Int64,
) -> Result[Array[QuicDriverAction], QuicError] {
  if now_ms < 0L {
    return Err(InvalidPacket("QUIC clock cannot be negative"))
  }
  guard self.state() == Established && self.local_ids is Some(ids) else {
    return Err(
      Unsupported(
        "local CID rotation requires an established connection with issuance enabled",
      ),
    )
  }
  if ids.active[0].sequence < ids.floor {
    return Ok([])
  }
  if ids.active.length() == 1 && ids.issued.length() >= ids.max_issued {
    return Err(LimitExceeded("local CID lifetime budget", ids.max_issued))
  }
  ids.rotate_from = Some(ids.active[0].sequence)
  let output = []
  self.advertise_local_cid(now_ms, output) catch {
    error => return Err(error)
  }
  Ok(output)
}

///|
fn QuicDatagramDriver::local_cid_sequence(
  self : QuicDatagramDriver,
  bytes : BytesView,
) -> Int64? {
  if self.local_ids is Some(ids) {
    for entry in ids.active {
      if bytes.equal_to_bytes(entry.id.bytes()) {
        return Some(entry.sequence)
      }
    }
    None
  } else if bytes.equal_to_bytes(self.local_connection_id.bytes()) {
    Some(0L)
  } else {
    None
  }
}

///|
fn QuicDatagramDriver::unknown_destination(
  self : QuicDatagramDriver,
) -> Result[Array[QuicDriverAction], QuicError] {
  // Packets still in flight on a retired route may reach a dedicated socket.
  if self.local_ids is Some(_) {
    Ok([PacketIgnored])
  } else {
    Err(InvalidPacket("destination does not match this QUIC connection"))
  }
}

///|
fn LocalConnectionIds::reserve_spare(
  self : LocalConnectionIds,
  length : Int,
) -> QuicConnectionId raise QuicError {
  for _ in 0..<8 {
    let spare = match self.pending {
      Some(value) => value
      None => {
        let id = ConnectionId::random(self.entropy, length~).unwrap_or_error()
        let token = FixedArray::make(16, b'\x00')
        match self.entropy.fill(token) {
          Err(error) => raise Entropy(error)
          Ok(_) => ()
        }
        {
          sequence: self.issued.length().to_int64(),
          id,
          reset_token: token.unsafe_reinterpret_as_bytes(),
          retired: false,
        }
      }
    }
    if !self.issued.contains(spare.id.bytes()) &&
      !self.tokens.contains(spare.reset_token) &&
      (self.reserve)(spare.id) {
      self.pending = Some(spare)
      return spare
    }
    self.pending = None
  }
  raise Entropy(
    Failed("could not allocate a unique local connection ID and reset token"),
  )
}

///|
fn QuicDatagramDriver::advertise_local_cid(
  self : QuicDatagramDriver,
  now_ms : Int64,
  output : Array[QuicDriverAction],
) -> Unit raise QuicError {
  guard self.local_ids is Some(ids) else { return }
  // RFC 9000 requires peers to accept at least two active IDs. Keep one spare.
  let fresh = ids.active.length() < 2
  if (fresh && ids.issued.length() >= ids.max_issued) ||
    (!fresh && ids.rotate_from is None) {
    return
  }
  let spare = if fresh {
    ids.reserve_spare(self.local_connection_id.bytes().length())
  } else {
    ids.active[1]
  }
  let floor = if ids.rotate_from is Some(_) {
    spare.sequence
  } else {
    ids.floor.max(ids.active[0].sequence)
  }
  let frame = NewConnectionId(
    spare.sequence,
    floor,
    spare.id,
    spare.reset_token,
  )
  match
    self.send_frames_internal_to(
      Application,
      [frame],
      now_ms,
      Regular,
      self.path.active(),
    ) {
    Ok(packet) => {
      if fresh {
        ids.active.push(spare)
        ids.issued.add(spare.id.bytes())
        ids.tokens.add(spare.reset_token)
        ids.pending = None
      }
      ids.floor = floor
      ids.rotate_from = None
      output.push(packet)
    }
    Err(error) => {
      if fresh {
        (ids.release)(spare.id)
      }
      if !error.send_blocked() {
        raise error
      }
    }
  }
}

///|
fn QuicDatagramDriver::retire_local_cid(
  self : QuicDatagramDriver,
  sequence : Int64,
) -> Unit {
  guard self.local_ids is Some(ids) else { return }
  for index in 0..<ids.active.length() {
    let entry = ids.active[index]
    if entry.sequence == sequence {
      ignore(ids.active.remove(index))
      if ids.rotate_from == Some(sequence) {
        ids.rotate_from = None
      }
      (ids.release)(entry.id)
      self.discard_application_retransmissions(frame => {
        frame is NewConnectionId(seq, _, _, _) && seq == sequence
      })
      return
    }
  }
}
