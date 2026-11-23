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
  if number > QUIC_MAX_VARINT {
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
fn QuicDatagramDriver::packet_layout(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
  payload : Bytes,
  minimum : Int,
) -> Result[QuicPacketLayout, QuicError] {
  let (packet_number, packet_number_length) = match
    self.quic_driver_next_number(space) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let maximum = self.send_datagram_limit()
  match space {
    Initial | Handshake =>
      quic_long_layout(
        if space == Initial {
          0
        } else {
          2
        },
        {
          version: QUIC_VERSION_1,
          destination: self.peer_connection_id,
          source: self.local_connection_id,
          token: if space == Initial {
            self.initial_token
          } else {
            b""
          },
          packet_number,
          packet_number_length,
          min_datagram_size: minimum,
          max_datagram_size: maximum,
        },
        payload,
      )
    Application =>
      quic_short_layout(
        self.peer_connection_id,
        packet_number,
        packet_number_length,
        payload,
        minimum,
        maximum,
      )
  }
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
  self.send_frames_internal_to(
    space,
    frames,
    now_ms,
    Regular,
    self.path.active(),
  )
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
/// Builds a packet for an explicit destination. Path validation uses this
/// entry point so PATH_CHALLENGE and its retransmissions stay on the
/// candidate path until validation succeeds.
fn QuicDatagramDriver::send_frames_internal_to(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
  frames : Array[QuicFrame],
  now_ms : Int64,
  mode : QuicSendMode,
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
  if frames.any(fn(frame) { frame is NewConnectionId(_, _, _, _) }) {
    return Err(
      Unsupported("local connection ID issuance and rotation are not supported"),
    )
  }
  match
    quic_validate_packet_frames(space, frames, from_server=self.role == Server) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let retransmittable = frames.any(quic_frame_is_retransmittable)
  if retransmittable &&
    mode is Regular &&
    self.retransmissions.length() >= self.recovery.config.max_tracked_packets {
    return Err(
      LimitExceeded(
        "QUIC retransmission queue",
        self.recovery.config.max_tracked_packets,
      ),
    )
  }
  let (payload, padding_offset) = quic_write_frames(frames, self.limits) catch {
    error => return Err(error)
  }
  if payload.is_empty() {
    return Err(InvalidFrame("cannot send an empty QUIC packet"))
  }
  let ack_eliciting = frames.any(quic_frame_is_ack_eliciting)
  let minimum = match space {
    Initial if self.role == Client || ack_eliciting => 1200
    Application if frames.any(fn(frame) {
        frame is (PathChallenge(_) | PathResponse(_))
      }) => 1200
    _ => 0
  }
  let mut layout = match self.packet_layout(space, payload, minimum) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let padded = layout.padding > 0 || padding_offset is Some(_)
  let feedback_at = if !ack_eliciting &&
    padded &&
    !frames.any(frame => frame is ConnectionClose(_, _, _, _)) &&
    self.recovery.needs_padding_feedback(layout.wire_size()) {
    // Periodically elicit an ACK before padding absorbs all available credit.
    // A server Initial carrying PING must be at least 1,200 bytes.
    if space == Initial && layout.wire_size() < 1200 {
      layout = match self.packet_layout(space, payload, 1200) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
    }
    Some(padding_offset.unwrap_or(payload.length()))
  } else {
    None
  }
  let packet_number = layout.number
  let packet_size = layout.wire_size()
  let meta : QuicSentPacket = {
    number: packet_number,
    space,
    bytes: packet_size,
    sent_at_ms: now_ms,
    ack_eliciting: ack_eliciting || feedback_at is Some(_),
    retransmittable,
  }
  let in_flight = ack_eliciting || padded
  match self.check_amplification(destination, packet_size) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let probe = mode is Probe(_)
  match self.recovery.check_sent(meta, in_flight, probe~) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match self.check_aead_send_limit(space) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let keys = match self.quic_driver_space_keys(space, true) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  self.count_encrypted_packet(space)
  let packet = match
    layout.seal(keys, key_phase=self.key_update.send_phase, feedback_at~) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  self.recovery.record_sent(meta, in_flight, probe~)
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
  match mode {
    Retransmit(entry) | Probe(Some(entry)) => {
      if entry.first is None {
        entry.first = Some(packet_number)
      }
      entry.live.push(packet_number)
    }
    Regular if retransmittable =>
      self.queue_retransmission(space, packet_number, destination, frames)
    _ => ()
  }
  if space == Handshake && self.role == Client {
    self.discard_packet_space(Initial)
  }
  Ok(SendDatagram(destination, packet))
}
