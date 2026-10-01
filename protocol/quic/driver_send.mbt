///|
fn QuicDatagramDriver::quic_driver_next_number(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
) -> Result[(Int64, Int), QuicError] {
  let number = match space {
    Initial => self.next_initial_packet
    Handshake => self.next_handshake_packet
    Application => self.next_application_packet
  }
  if number >= QUIC_MAX_VARINT {
    return Err(VarIntOverflow)
  }
  let length = if number <= 0xffL {
    1
  } else if number <= 0xffffL {
    2
  } else if number <= 0xffffffL {
    3
  } else {
    4
  }
  Ok((number, length))
}

///|
fn QuicDatagramDriver::quic_driver_commit_number(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
) -> Unit {
  match space {
    Initial => self.next_initial_packet += 1L
    Handshake => self.next_handshake_packet += 1L
    Application => self.next_application_packet += 1L
  }
}

///|
fn QuicDatagramDriver::quic_driver_build_packet(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
  payload : Bytes,
) -> Result[(Int64, Bytes), QuicError] {
  let keys = match self.quic_driver_space_keys(space, true) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (packet_number, packet_number_length) = match
    self.quic_driver_next_number(space) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let packet = match space {
    Initial => {
      let options = {
        ..QuicInitialPacketOptions::defaults(
          self.peer_connection_id,
          self.local_connection_id,
          packet_number,
        ),
        token: self.initial_token,
        packet_number_length,
        max_datagram_size: self.send_datagram_limit(),
      }
      match quic_build_initial_packet(keys, options, payload) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
    }
    Handshake =>
      match
        quic_build_long_packet(
          keys,
          2,
          QUIC_VERSION_1,
          self.peer_connection_id,
          self.local_connection_id,
          b"",
          packet_number,
          packet_number_length,
          payload,
          min_datagram_size=0,
          max_datagram_size=self.send_datagram_limit(),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
    Application =>
      match
        quic_build_short_packet(
          keys,
          self.peer_connection_id,
          packet_number,
          packet_number_length,
          payload,
          key_phase=self.key_update.send_phase,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
  }
  Ok((packet_number, packet))
}

///|
/// Builds and accounts for one outgoing packet.  The returned action is safe
/// to hand to a datagram capability; no socket is touched here.
pub fn QuicDatagramDriver::send_frames(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
  frames : Array[QuicFrame],
  now_ms : Int64,
) -> Result[QuicDriverAction, QuicError] {
  self.send_frames_internal(space, frames, now_ms, false, None)
}

///|
/// Creates a server Retry response after an Initial has identified the peer.
/// The caller is responsible for deciding whether address validation is
/// required and for producing a bounded, self-authenticating token. The driver
/// authenticates the Retry tag, enforces anti-amplification, and records the
/// complete datagram before handing it to UDP.
fn QuicDatagramDriver::send_retry(
  self : QuicDatagramDriver,
  destination : @types.Endpoint,
  token : Bytes,
) -> Result[QuicDriverAction, QuicError] {
  if self.role != Server || self.state() != Handshaking {
    return Err(Unsupported("Retry can only be sent by a handshaking server"))
  }
  if token.is_empty() {
    return Err(InvalidPacket("Retry token cannot be empty"))
  }
  let packet = match
    quic_build_retry_packet(
      QUIC_VERSION_1,
      self.peer_connection_id,
      self.local_connection_id,
      token,
      self.original_destination,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match self.check_amplification(destination, packet.length()) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  self.count_sent_datagram(destination, packet.length())
  Ok(SendDatagram(destination, packet))
}

///|
/// Issues a Retry token with the configured manager and emits the authenticated
/// Retry packet. Both capabilities are explicit; the driver never falls back
/// to a weak clock or nonce source.
pub fn[C : @transport.Clock, E : @transport.Entropy] QuicDatagramDriver::send_retry_validated(
  self : QuicDatagramDriver,
  destination : @types.Endpoint,
  clock : C,
  entropy : E,
) -> Result[QuicDriverAction, QuicError] {
  let manager = match self.retry_tokens {
    Some(value) => value
    None => return Err(Unsupported("Retry token manager is not configured"))
  }
  let token = match
    manager.issue(
      destination,
      self.original_destination,
      self.local_connection_id,
      self.peer_connection_id,
      clock,
      entropy,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  self.send_retry(destination, token)
}

///|
fn QuicDatagramDriver::send_frames_internal(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
  frames : Array[QuicFrame],
  now_ms : Int64,
  congestion_exempt : Bool,
  replacement_number : Int64?,
) -> Result[QuicDriverAction, QuicError] {
  self.send_frames_internal_to(
    space,
    frames,
    now_ms,
    congestion_exempt,
    replacement_number,
    self.path.active(),
  )
}

///|
/// Builds a packet for an explicit destination. Path validation uses this
/// entry point so PATH_CHALLENGE and its retransmissions stay on the
/// candidate path until validation succeeds.
fn QuicDatagramDriver::send_frames_internal_to(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
  frames : Array[QuicFrame],
  now_ms : Int64,
  congestion_exempt : Bool,
  replacement_number : Int64?,
  destination : @types.Endpoint,
) -> Result[QuicDriverAction, QuicError] {
  if now_ms < 0L {
    return Err(InvalidPacket("QUIC clock cannot be negative"))
  }
  guard self.state() != Closed && self.state() != Draining else {
    return Err(ConnectionClosed(0L, "connection is closed"))
  }
  if space == Application && self.state() != Established {
    return Err(
      Unsupported("application packets require an established connection"),
    )
  }
  match self.check_aead_send_limit(space) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match quic_validate_frames_for_space(space, frames) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let retransmittable = quic_frames_are_retransmittable(frames)
  let replacing = match replacement_number {
    None => false
    Some(number) => {
      let mut found = false
      for entry in self.retransmissions {
        if entry.space == space && entry.number == number && entry.pending {
          found = true
          break
        }
      }
      if !found || !retransmittable {
        return Err(InvalidPacket("invalid QUIC retransmission replacement"))
      }
      true
    }
  }
  if retransmittable &&
    !replacing &&
    self.retransmissions.length() >= self.max_retransmissions {
    return Err(
      LimitExceeded("QUIC retransmission queue", self.max_retransmissions),
    )
  }
  let mut payload = match quic_encode_frames(frames, limits=self.limits) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if payload.is_empty() {
    return Err(InvalidFrame("cannot send an empty QUIC packet"))
  }
  let has_path_probe = frames.any(fn(frame) {
    match frame {
      PathChallenge(_) | PathResponse(_) => true
      _ => false
    }
  })
  if space == Application && has_path_probe {
    let (_, number_length) = match self.quic_driver_next_number(space) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let minimum_payload = 1200 -
      (1 + self.peer_connection_id.bytes().length() + number_length + 16)
    if payload.length() < minimum_payload {
      let padding = FixedArray::make(
        minimum_payload - payload.length(),
        b'\x00',
      )
      payload = quic_driver_join([
        payload,
        padding.unsafe_reinterpret_as_bytes(),
      ])
    }
  }
  let (packet_number, packet) = match
    self.quic_driver_build_packet(space, payload) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  // The AEAD operation already consumed the key's security budget even if
  // congestion or amplification prevents this packet from reaching UDP.
  self.count_encrypted_packet(space)
  let packet_size = packet.length()
  if packet_size > self.send_datagram_limit() {
    return Err(LimitExceeded("QUIC datagram", self.send_datagram_limit()))
  }
  match self.check_amplification(destination, packet_size) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match
    self.recovery.on_packet_sent(
      {
        number: packet_number,
        space,
        bytes: packet_size,
        sent_at_ms: now_ms,
        ack_eliciting: frames.any(quic_frame_is_ack_eliciting),
        retransmittable,
      },
      congestion_exempt~,
    ) {
    Ok(_) => {
      self.count_sent_datagram(destination, packet_size)
      self.quic_driver_commit_number(space)
      if space == Application &&
        frames.any(fn(frame) {
          match frame {
            Ack(ack) =>
              ack.largest_acknowledged() >= self.key_update.receive_phase_start
            _ => false
          }
        }) {
        self.key_update.receive_phase_acked = true
      }
      if retransmittable {
        match replacement_number {
          Some(number) =>
            if self.take_retransmission(space, number) is None {
              // The entry was checked before recovery state was mutated. This
              // branch is unreachable without internal state corruption.
              self.connection.state = Closed
              return Err(InvalidPacket("QUIC retransmission state changed"))
            }
          None => ()
        }
        self.queue_retransmission(space, packet_number, destination, frames)
      }
      Ok(SendDatagram(destination, packet))
    }
    Err(error) => Err(error)
  }
}
