///|
/// Directional key generations share packet numbers, but have independent
/// acknowledgment gates. Header protection stays unchanged across updates.
priv struct QuicKeyUpdateState {
  mut confirmed : Bool
  mut send_phase : Bool
  mut receive_phase : Bool
  mut send_generation : Int
  mut receive_generation : Int
  mut send_phase_start : Int64
  mut receive_phase_start : Int64
  mut send_phase_acked : Bool
  mut receive_phase_acked : Bool
  mut next_receive : @tls.QuicPacketKeys?
  mut previous_receive : @tls.QuicPacketKeys?
  mut previous_until_ms : Int64
  // RFC 9001 section 6.6 counts encrypted packets, even if congestion or
  // amplification checks later prevent a built packet from being sent.
  mut initial_send_packets : Int64
  mut handshake_send_packets : Int64
  mut send_packets : Int64
  mut receive_failures : Int64
}

///|
fn QuicKeyUpdateState::new() -> QuicKeyUpdateState {
  {
    confirmed: false,
    send_phase: false,
    receive_phase: false,
    send_generation: 0,
    receive_generation: 0,
    send_phase_start: 0L,
    receive_phase_start: 0L,
    send_phase_acked: false,
    receive_phase_acked: false,
    next_receive: None,
    previous_receive: None,
    previous_until_ms: 0L,
    initial_send_packets: 0L,
    handshake_send_packets: 0L,
    send_packets: 0L,
    receive_failures: 0L,
  }
}

///|
pub fn QuicDatagramDriver::handshake_confirmed(
  self : QuicDatagramDriver,
) -> Bool {
  self.key_update.confirmed
}

///|
/// RFC 9001 section 6.1: a local update requires handshake confirmation and
/// an acknowledgment of a packet sent using the current keys. The peer must
/// have caught up with the preceding update before another is initiated.
pub fn QuicDatagramDriver::initiate_key_update(
  self : QuicDatagramDriver,
) -> Result[Unit, QuicError] {
  let state = self.key_update
  if self.state() != Established ||
    !state.confirmed ||
    !state.send_phase_acked ||
    state.send_generation != state.receive_generation {
    return Err(
      Unsupported(
        "key update requires handshake confirmation and acknowledgment of the current phase",
      ),
    )
  }
  self.advance_send_keys()
}

///|
fn QuicDatagramDriver::advance_send_keys(
  self : QuicDatagramDriver,
) -> Result[Unit, QuicError] {
  let current = match self.application_send_keys {
    Some(value) => value
    None => return Err(Unsupported("application send keys are unavailable"))
  }
  let next = match current.next_application_keys() {
    Ok(value) => value
    Err(error) => return Err(Tls(error))
  }
  self.application_send_keys = Some(next)
  self.key_update.send_phase = !self.key_update.send_phase
  self.key_update.send_generation += 1
  self.key_update.send_phase_start = self.next_application_packet
  self.key_update.send_phase_acked = false
  self.key_update.send_packets = 0L
  Ok(())
}

///|
/// Decryption alone does not commit a phase change. The caller first validates
/// the complete packet and its path, then promotes keys exactly once.
fn QuicDatagramDriver::open_application_packet(
  self : QuicDatagramDriver,
  packet : Bytes,
  offset : Int,
  now_ms : Int64,
) -> Result[(QuicOpenedPacket, Bool), QuicError] {
  let current = match self.application_receive_keys {
    Some(value) => value
    None => return Err(Unsupported("application receive keys are unavailable"))
  }
  let state = self.key_update
  if state.previous_receive is Some(_) && now_ms >= state.previous_until_ms {
    state.previous_receive = None
  }
  let current_error = match
    quic_open_packet_with_keys(
      current,
      packet,
      offset,
      self.largest_application_received,
      false,
    ) {
    Ok(opened) => {
      if opened.key_phase() != state.receive_phase {
        return Err(
          self.key_update_failure("key phase does not match authenticated keys"),
        )
      }
      return Ok((opened, false))
    }
    Err(error) => error
  }
  if state.next_receive is Some(next) {
    match
      quic_open_packet_with_keys(
        next,
        packet,
        offset,
        self.largest_application_received,
        false,
      ) {
      Ok(opened) => {
        if opened.key_phase() == state.receive_phase ||
          opened.packet_number() <= self.largest_application_received {
          return Err(
            self.key_update_failure(
              "key update must advance phase and packet number",
            ),
          )
        }
        if !state.confirmed ||
          (state.receive_generation > 0 && !state.receive_phase_acked) {
          return Err(
            self.key_update_failure(
              "peer updated keys before handshake confirmation or phase acknowledgment",
            ),
          )
        }
        return Ok((opened, true))
      }
      Err(_) => ()
    }
  }
  if state.previous_receive is Some(previous) {
    match
      quic_open_packet_with_keys(
        previous,
        packet,
        offset,
        self.largest_application_received,
        false,
      ) {
      Ok(opened) => {
        if opened.key_phase() == state.receive_phase ||
          opened.packet_number() >= state.receive_phase_start {
          return Err(
            self.key_update_failure(
              "old-phase packet number crosses the key update boundary",
            ),
          )
        }
        return Ok((opened, false))
      }
      Err(_) => ()
    }
  }
  Err(current_error)
}

///|
fn QuicDatagramDriver::advance_receive_keys(
  self : QuicDatagramDriver,
  first_packet : Int64,
  now_ms : Int64,
) -> Result[Unit, QuicError] {
  let state = self.key_update
  let next = match state.next_receive {
    Some(value) => value
    None => return Err(Unsupported("next receive keys are unavailable"))
  }
  let following = match next.next_application_keys() {
    Ok(value) => value
    Err(error) => return Err(Tls(error))
  }
  // The response and ACK must use the new sending keys (RFC 9001 section 6.1).
  if state.send_generation == state.receive_generation {
    match self.advance_send_keys() {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  state.previous_receive = self.application_receive_keys
  state.previous_until_ms = now_ms +
    self.recovery.recovery_pto(Application).min((QUIC_MAX_VARINT - now_ms) / 3L) *
    3L
  self.application_receive_keys = Some(next)
  state.next_receive = Some(following)
  state.receive_phase = !state.receive_phase
  state.receive_generation += 1
  state.receive_phase_start = first_packet
  state.receive_phase_acked = false
  Ok(())
}

///|
/// Count only AEAD decryption failures. Malformed headers and frame
/// violations are protocol errors, not AEAD forgery attempts.
fn QuicDatagramDriver::record_authentication_failure(
  self : QuicDatagramDriver,
  error : QuicError,
) -> QuicError {
  if error is Tls(PacketAuthenticationFailed) {
    self.key_update.receive_failures += 1L
    if self.key_update.receive_failures >= QUIC_AEAD_INTEGRITY_LIMIT {
      self.connection.state = Closed
      return Protocol(
        QUIC_AEAD_LIMIT_REACHED,
        "QUIC AEAD integrity limit reached",
      )
    }
  }
  error
}

///|
fn QuicDatagramDriver::key_update_failure(
  self : QuicDatagramDriver,
  reason : String,
) -> QuicError {
  self.connection.state = Closed
  Protocol(QUIC_KEY_UPDATE_ERROR, reason)
}

///|
fn QuicDatagramDriver::check_aead_send_limit(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
) -> Result[Unit, QuicError] {
  let used = match space {
    Initial => self.key_update.initial_send_packets
    Handshake => self.key_update.handshake_send_packets
    Application => self.key_update.send_packets
  }
  if used < QUIC_AEAD_CONFIDENTIALITY_LIMIT {
    return Ok(())
  }
  if space == Application {
    match self.initiate_key_update() {
      Ok(_) => return Ok(())
      Err(_) => ()
    }
  }
  self.connection.state = Closed
  Err(
    Protocol(QUIC_AEAD_LIMIT_REACHED, "QUIC AEAD confidentiality limit reached"),
  )
}

///|
fn QuicDatagramDriver::count_encrypted_packet(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
) -> Unit {
  match space {
    Initial => self.key_update.initial_send_packets += 1L
    Handshake => self.key_update.handshake_send_packets += 1L
    Application => self.key_update.send_packets += 1L
  }
}
