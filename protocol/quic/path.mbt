///|
pub(all) enum QuicPathStatus {
  PathActive
  PathChallenging
  PathValidated
  PathFailed
} derive(Eq, Debug)

///|
pub(all) struct QuicPathManager {
  mut active : @types.Endpoint
  mut candidate : @types.Endpoint?
  mut challenge : Bytes?
  mut status : QuicPathStatus
  mut generation : Int64
} derive(Debug)

///|
pub fn QuicPathManager::new(endpoint : @types.Endpoint) -> QuicPathManager {
  {
    active: endpoint,
    candidate: None,
    challenge: None,
    status: PathActive,
    generation: 0L,
  }
}

///|
pub fn QuicPathManager::active(self : QuicPathManager) -> @types.Endpoint {
  self.active
}

///|
pub fn QuicPathManager::candidate(self : QuicPathManager) -> @types.Endpoint? {
  self.candidate
}

///|
pub fn QuicPathManager::status(self : QuicPathManager) -> QuicPathStatus {
  self.status
}

///|
pub fn QuicPathManager::generation(self : QuicPathManager) -> Int64 {
  self.generation
}

///|
/// Starts validation of a new network path. Challenge bytes must come from
/// the caller's Entropy capability and are never generated internally.
pub fn QuicPathManager::begin(
  self : QuicPathManager,
  endpoint : @types.Endpoint,
  challenge : Bytes,
) -> Result[Unit, QuicError] {
  match self.validate_candidate(endpoint, challenge) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  self.candidate = Some(endpoint)
  self.challenge = Some(challenge)
  self.status = PathChallenging
  Ok(())
}

///|
fn QuicPathManager::validate_candidate(
  self : QuicPathManager,
  endpoint : @types.Endpoint,
  challenge : Bytes,
) -> Result[Unit, QuicError] {
  if endpoint == self.active {
    return Err(InvalidPacket("path migration target is already active"))
  }
  if challenge.length() != 8 {
    return Err(InvalidPacket("PATH_CHALLENGE must contain eight bytes"))
  }
  Ok(())
}

///|
fn QuicPathManager::matches_response(
  self : QuicPathManager,
  response : Bytes,
) -> Bool {
  self.candidate is Some(_) && self.challenge == Some(response)
}

///|
pub fn QuicPathManager::on_response(
  self : QuicPathManager,
  endpoint : @types.Endpoint,
  response : Bytes,
) -> Result[Unit, QuicError] {
  ignore(endpoint)
  guard self.candidate is Some(candidate) else {
    return Err(InvalidPacket("unexpected PATH_RESPONSE"))
  }
  guard self.challenge is Some(challenge) else {
    return Err(InvalidPacket("path challenge is missing"))
  }
  guard challenge == response else {
    return Err(InvalidPacket("PATH_RESPONSE does not match challenge"))
  }
  // RFC 9000 section 8.2.3 permits a matching response on any path. The
  // response validates the path the challenge was sent to, not its source.
  self.active = candidate
  self.candidate = None
  self.challenge = None
  self.status = PathValidated
  self.generation += 1L
  Ok(())
}

///|
pub fn QuicPathManager::abandon(self : QuicPathManager) -> Unit {
  self.candidate = None
  self.challenge = None
  self.status = PathActive
}

///|
pub(all) struct QuicConnectionId {
  sequence : Int64
  id : ConnectionId
  reset_token : Bytes
  mut retired : Bool
} derive(Eq, Debug)

///|
pub fn QuicConnectionId::sequence(self : QuicConnectionId) -> Int64 {
  self.sequence
}

///|
pub fn QuicConnectionId::id(self : QuicConnectionId) -> ConnectionId {
  self.id
}

///|
pub fn QuicConnectionId::retired(self : QuicConnectionId) -> Bool {
  self.retired
}

///|
pub struct QuicConnectionIdManager {
  mut ids : Array[QuicConnectionId]
  max_active : Int
  mut retire_prior_to : Int64
} derive(Debug)

///|
priv struct QuicConnectionIdUpdate {
  ids : Array[QuicConnectionId]
  retire_prior_to : Int64
  retirements : Array[Int64]
}

///|
pub fn QuicConnectionIdManager::new(
  initial : ConnectionId,
  max_active? : Int = 2,
) -> Result[QuicConnectionIdManager, QuicError] {
  if max_active < 1 {
    return Err(LimitExceeded("active connection IDs", max_active))
  }
  Ok({
    ids: [{ sequence: 0L, id: initial, reset_token: b"", retired: false, }],
    max_active,
    retire_prior_to: 0L,
  })
}

///|
pub fn QuicConnectionIdManager::active(
  self : QuicConnectionIdManager,
) -> Array[QuicConnectionId] {
  let result : Array[QuicConnectionId] = []
  for value in self.ids {
    if !value.retired {
      result.push(value)
    }
  }
  result
}

///|
pub fn QuicConnectionIdManager::receive(
  self : QuicConnectionIdManager,
  sequence : Int64,
  retire_prior_to : Int64,
  id : ConnectionId,
  reset_token : Bytes,
) -> Result[Unit, QuicError] {
  match self.prepare_announcement(sequence, retire_prior_to, id, reset_token) {
    Ok(update) => {
      self.apply_update(update)
      Ok(())
    }
    Err(error) => Err(error)
  }
}

///|
/// Peer-issued CID state only. Build the new bounded set before committing it;
/// malformed announcements must not retire the currently selected destination.
/// The caller sends RETIRE_CONNECTION_ID for the returned sequence numbers.
fn QuicConnectionIdManager::prepare_announcement(
  self : QuicConnectionIdManager,
  sequence : Int64,
  retire_prior_to : Int64,
  id : ConnectionId,
  reset_token : Bytes,
) -> Result[QuicConnectionIdUpdate, QuicError] {
  if sequence < 0L ||
    sequence > QUIC_MAX_VARINT ||
    retire_prior_to < 0L ||
    retire_prior_to > sequence ||
    id.bytes().is_empty() ||
    reset_token.length() != 16 {
    return Err(InvalidFrame("invalid NEW_CONNECTION_ID"))
  }
  if self.ids.any(fn(value) { value.id.bytes().is_empty() }) {
    return Err(
      Protocol(0x0aL, "NEW_CONNECTION_ID after a zero-length initial CID"),
    )
  }
  if sequence < self.retire_prior_to {
    // Reordered announcements below the floor must be retired again, without
    // retaining their metadata or reactivating them.
    return Ok({
      ids: self.ids,
      retire_prior_to: self.retire_prior_to,
      retirements: [sequence],
    })
  }
  let floor = self.retire_prior_to.max(retire_prior_to)
  let retained : Array[QuicConnectionId] = []
  let retirements : Array[Int64] = []
  let mut duplicate = false
  for value in self.ids {
    if value.sequence == sequence {
      if value.id != id ||
        (!value.reset_token.is_empty() && value.reset_token != reset_token) {
        return Err(Protocol(0x0aL, "connection ID sequence was reused"))
      }
      duplicate = true
    } else if value.id == id {
      return Err(
        Protocol(0x0aL, "connection ID was reused with a different sequence"),
      )
    }
    if value.sequence < floor {
      if !value.retired {
        retirements.push(value.sequence)
      }
    } else if value.sequence == sequence {
      retained.push({ ..value, reset_token, })
      if value.retired {
        retirements.push(sequence)
      }
    } else {
      retained.push(value)
    }
  }
  if !duplicate {
    retained.push({ sequence, id, reset_token, retired: false, })
  }
  let active_count = retained.filter(fn(value) { !value.retired }).length()
  if active_count > self.max_active {
    return Err(LimitExceeded("active connection IDs", self.max_active))
  }
  // Standalone callers can retire individual peer IDs. Keep those tombstones
  // for reuse checks, but do not let that API bypass the metadata budget.
  if retained.length() > self.max_active {
    return Err(LimitExceeded("connection ID history", self.max_active))
  }
  Ok({ ids: retained, retire_prior_to: floor, retirements, })
}

///|
fn QuicConnectionIdManager::apply_update(
  self : QuicConnectionIdManager,
  update : QuicConnectionIdUpdate,
) -> Unit {
  self.retire_prior_to = update.retire_prior_to
  self.ids = update.ids
}

///|
pub fn QuicConnectionIdManager::retire(
  self : QuicConnectionIdManager,
  sequence : Int64,
) -> Result[Unit, QuicError] {
  for value in self.ids {
    if value.sequence == sequence {
      if value.retired {
        return Ok(())
      }
      if self.active().length() == 1 {
        return Err(Protocol(0x6L, "cannot retire the active connection ID"))
      }
      value.retired = true
      return Ok(())
    }
  }
  Err(Protocol(0x6L, "unknown connection ID sequence"))
}
