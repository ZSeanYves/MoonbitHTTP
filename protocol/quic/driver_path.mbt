///|
/// Starts path validation and immediately returns the datagram action that
/// carries PATH_CHALLENGE to the candidate endpoint.  The challenge is also
/// retained by recovery, so a PTO retransmits it to the same candidate until
/// a matching PATH_RESPONSE validates the path.
pub fn QuicDatagramDriver::begin_path_validation(
  self : QuicDatagramDriver,
  endpoint : @types.Endpoint,
  challenge : Bytes,
  now_ms : Int64,
) -> Result[QuicDriverAction, QuicError] {
  if self.peer_parameters is Some(params) &&
    params.limits.disable_active_migration {
    return Err(InvalidTransportParameter("peer disabled active migration"))
  }
  match (self.authorize_endpoint)(endpoint, QuicEndpoint) {
    Ok(_) => ()
    Err(error) => return Err(Policy(error))
  }
  match self.path.validate_candidate(endpoint, challenge) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  // A fresh destination receives a separate budget; the active path's
  // validated status and receive credit never authorize another address.
  if self.candidate_budget is None ||
    self.candidate_budget.unwrap().endpoint != endpoint {
    self.candidate_budget = Some(
      QuicPathBudget::new(endpoint, self.role == Client),
    )
  }
  match
    self.send_frames_internal_to(
      Application,
      [PathChallenge(challenge)],
      now_ms,
      Regular,
      endpoint,
    ) {
    Ok(action) =>
      // Prevalidated above; commit path state only after packet construction
      // and recovery accounting have both succeeded.
      match self.path.begin(endpoint, challenge) {
        Ok(_) => Ok(action)
        Err(error) => Err(error)
      }
    Err(error) => Err(error)
  }
}

///|
fn QuicDatagramDriver::discard_path_challenges(
  self : QuicDatagramDriver,
) -> Unit {
  let mut index = self.retransmissions.length() - 1
  while index >= 0 {
    if self.retransmissions[index].endpoint is Some(_) {
      self.retransmissions.remove(index) |> ignore
    }
    index -= 1
  }
}

///|
pub fn QuicDatagramDriver::poll(
  self : QuicDatagramDriver,
  now_ms : Int64,
) -> Result[Array[QuicDriverAction], QuicError] {
  if self.state() == Closed || self.state() == Draining {
    return if now_ms < 0L {
      Err(InvalidPacket("recovery clock cannot be negative"))
    } else {
      Ok([])
    }
  }
  // A client whose address validation is still outstanding can need a probe
  // even after the server has acknowledged its complete Initial flight.
  let validation_space : PacketNumberSpace? = if self.role == Client &&
    !self.peer_address_validated &&
    !self.key_update.confirmed &&
    (
      self.next_initial_packet > 0L ||
      self.next_handshake_packet > 0L ||
      self.state() == Established
    ) {
    if self.handshake_send_keys is Some(_) {
      Some(Handshake)
    } else if self.initial_send_keys is Some(_) {
      Some(Initial)
    } else {
      None
    }
  } else {
    None
  }
  let events = match
    self.recovery.timer_events(
      now_ms,
      self.key_update.confirmed,
      validation_space,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let output : Array[QuicDriverAction] = []
  for event in events {
    match event {
      IdleTimeout => {
        self.connection.state = Closed
        output.push(ConnectionClosed(0L, "QUIC idle timeout"))
      }
      ProbeTimeout(space) => {
        let packet = match self.send_probe(space, now_ms) {
          Ok(value) => value
          Err(error) if error.send_blocked() => continue
          Err(error) => return Err(error)
        }
        self.recovery.probe_sent(space, now_ms)
        output.push(packet)
      }
      PacketLost(number, space, _) =>
        self.note_retransmission_loss(space, number)
      PacketAcknowledged(_, _, _) => ()
    }
  }
  if self.state() == Closed || self.state() == Draining {
    return Ok(output)
  }
  for space in quic_number_spaces {
    let received = self.received(space)
    if received.pending_ack(space, self.limits, now_ms) is Some(ack) {
      match self.send_frames(space, [ack], now_ms) {
        Ok(action) => {
          received.pending = None
          output.push(action)
        }
        Err(error) if error.send_blocked() => ()
        Err(error) => return Err(error)
      }
    }
    let pending = match self.flush_pending_retransmissions(space, now_ms) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    output.append(pending)
  }
  match self.flush_retirements(now_ms) {
    Ok(actions) => output.append(actions)
    Err(error) => return Err(error)
  }
  if self.state() == Established {
    // The stream stays live until its reset is acknowledged, bounding this
    // queue by max_streams. Leave a blocked frame in place for the next poll.
    while self.pending_resets.front() is Some(reset) {
      match self.send_frames(Application, [reset], now_ms) {
        Ok(action) => {
          ignore(self.pending_resets.pop_front())
          output.push(action)
        }
        Err(error) if error.send_blocked() => break
        Err(error) => return Err(error)
      }
    }
    let frames = self.connection.credit_updates(
      self.application_payload_limit(),
    )
    if !frames.is_empty() {
      match self.send_frames(Application, frames, now_ms) {
        Ok(action) => {
          self.connection.commit_credit_updates(frames)
          output.push(action)
        }
        Err(error) if error.send_blocked() => ()
        Err(error) => return Err(error)
      }
    }
  }
  Ok(output)
}
