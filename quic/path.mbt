///|
pub(all) enum QuicPathStatus {
  PathActive
  PathChallenging
  PathValidated
  PathFailed
} derive(Eq, Debug)

///|
pub(all) struct QuicPathManager {
  mut active : @transport.Endpoint
  mut candidate : @transport.Endpoint?
  mut challenge : Bytes?
  mut status : QuicPathStatus
  mut generation : Int64
} derive(Debug)

///|
pub fn QuicPathManager::new(endpoint : @transport.Endpoint) -> QuicPathManager {
  {
    active: endpoint,
    candidate: None,
    challenge: None,
    status: PathActive,
    generation: 0L,
  }
}

///|
pub fn QuicPathManager::active(self : QuicPathManager) -> @transport.Endpoint {
  self.active
}

///|
pub fn QuicPathManager::candidate(
  self : QuicPathManager,
) -> @transport.Endpoint? {
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
  endpoint : @transport.Endpoint,
  challenge : Bytes,
) -> Result[Unit, QuicError] {
  if endpoint == self.active {
    return Err(InvalidPacket("path migration target is already active"))
  }
  if challenge.length() != 8 {
    return Err(InvalidPacket("PATH_CHALLENGE must contain eight bytes"))
  }
  self.candidate = Some(endpoint)
  self.challenge = Some(challenge)
  self.status = PathChallenging
  Ok(())
}

///|
pub fn QuicPathManager::on_response(
  self : QuicPathManager,
  endpoint : @transport.Endpoint,
  response : Bytes,
) -> Result[Unit, QuicError] {
  guard self.candidate is Some(candidate) else {
    return Err(InvalidPacket("unexpected PATH_RESPONSE"))
  }
  guard candidate == endpoint else {
    return Err(InvalidPacket("PATH_RESPONSE arrived on another path"))
  }
  guard self.challenge is Some(challenge) else {
    return Err(InvalidPacket("path challenge is missing"))
  }
  guard challenge == response else {
    self.status = PathFailed
    return Err(InvalidPacket("PATH_RESPONSE does not match challenge"))
  }
  self.active = endpoint
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
  ids : Array[QuicConnectionId]
  max_active : Int
  mut retire_prior_to : Int64
} derive(Debug)

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
  if sequence < 0L ||
    retire_prior_to < 0L ||
    retire_prior_to > sequence ||
    reset_token.length() != 16 {
    return Err(InvalidFrame("invalid NEW_CONNECTION_ID"))
  }
  if sequence < self.retire_prior_to {
    return Err(Protocol(0x6L, "connection ID sequence is retired"))
  }
  for value in self.ids {
    if value.sequence == sequence {
      if value.id != id || value.reset_token != reset_token {
        return Err(Protocol(0x6L, "connection ID sequence was reused"))
      }
      return Ok(())
    }
  }
  self.retire_prior_to = self.retire_prior_to.max(retire_prior_to)
  for value in self.ids {
    if value.sequence < self.retire_prior_to {
      value.retired = true
    }
  }
  let active_count = self.active().length()
  if active_count >= self.max_active {
    return Err(LimitExceeded("active connection IDs", self.max_active))
  }
  self.ids.push({ sequence, id, reset_token, retired: false, })
  Ok(())
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
      value.retired = true
      if self.active().is_empty() {
        return Err(Protocol(0x6L, "cannot retire the active connection ID"))
      }
      return Ok(())
    }
  }
  Err(Protocol(0x6L, "unknown connection ID sequence"))
}
