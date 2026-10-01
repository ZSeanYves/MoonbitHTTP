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
      false,
      None,
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
  let events = match
    self.recovery.poll(
      now_ms,
      application_confirmed=self.state() == Established,
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
        // A PTO probe is a new packet. Keep the source packet in recovery so
        // a late ACK still releases its own bytes-in-flight accounting.
        // Once the probe is accepted, its retained frames supersede the
        // source entry in the driver queue; recovery still tracks both packet
        // numbers independently.
        let (destination, probe_frames) = match
          self.recovery.oldest_probe_packet(space) {
          Some(packet) =>
            match self.retransmission_for_number(space, packet.number()) {
              Some((frames, endpoint)) => (endpoint, frames)
              None => (self.path.active(), [Ping])
            }
          None => (self.path.active(), [Ping])
        }
        let packet = match
          self.send_frames_internal_to(
            space,
            probe_frames,
            now_ms,
            true,
            None,
            destination,
          ) {
          Ok(value) => value
          Err(AmplificationBlocked) => continue
          Err(error) => return Err(error)
        }
        output.push(packet)
      }
      _ => ()
    }
  }
  let spaces : Array[PacketNumberSpace] = [Initial, Handshake, Application]
  for space in spaces {
    let pending = match self.flush_pending_retransmissions(space, now_ms) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    output.append(pending)
  }
  Ok(output)
}
