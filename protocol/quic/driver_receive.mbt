///|
fn QuicDatagramDriver::quic_driver_largest(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
) -> Int64 {
  match space {
    Initial => self.largest_initial_received
    Handshake => self.largest_handshake_received
    Application => self.largest_application_received
  }
}

///|
fn QuicDatagramDriver::quic_driver_seen(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
  number : Int64,
) -> Bool {
  let seen = match space {
    Initial => self.seen_initial
    Handshake => self.seen_handshake
    Application => self.seen_application
  }
  let largest = self.quic_driver_largest(space)
  (largest >= 4096L && number <= largest - 4096L) || seen.contains(number)
}

///|
fn QuicDatagramDriver::quic_driver_mark_seen(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
  number : Int64,
) -> Unit {
  match space {
    Initial => {
      self.seen_initial.push(number)
      if self.seen_initial.length() > 4096 {
        self.seen_initial.remove(0) |> ignore
      }
      self.largest_initial_received = self.largest_initial_received.max(number)
    }
    Handshake => {
      self.seen_handshake.push(number)
      if self.seen_handshake.length() > 4096 {
        self.seen_handshake.remove(0) |> ignore
      }
      self.largest_handshake_received = self.largest_handshake_received.max(
        number,
      )
    }
    Application => {
      self.seen_application.push(number)
      if self.seen_application.length() > 4096 {
        self.seen_application.remove(0) |> ignore
      }
      self.largest_application_received = self.largest_application_received.max(
        number,
      )
    }
  }
}

///|
fn quic_driver_packet_space(
  packet_type : Int,
) -> Result[PacketNumberSpace, QuicError] {
  match packet_type {
    0 => Ok(Initial)
    1 => Err(Unsupported("0-RTT is disabled without an explicit replay policy"))
    2 => Ok(Handshake)
    _ => Err(Unsupported("unsupported QUIC packet type"))
  }
}

///|
fn quic_driver_append_connection_actions(
  actions : Array[QuicDriverAction],
  connection_actions : Array[QuicAction],
  space : PacketNumberSpace,
) -> Result[Array[QuicFrame], QuicError] {
  let responses : Array[QuicFrame] = []
  for action in connection_actions {
    match action {
      StreamData(id, data, fin) => actions.push(StreamData(id, data, fin))
      StreamReset(id, code) => actions.push(StreamReset(id, code))
      ConnectionError(code, reason) => {
        actions.push(ConnectionClosed(code, reason))
        responses.push(ConnectionClose(true, code, 0L, b""))
      }
      PeerAck(_) => ()
      SendFrame(frame) => responses.push(frame)
      PacketIgnored => actions.push(PacketIgnored)
    }
  }
  ignore(space)
  Ok(responses)
}

///|
/// Opens one datagram and feeds all authenticated frames into the QUIC
/// connection.  A malformed or unauthenticated packet returns a typed error;
/// callers may choose to drop it at the transport boundary.
pub fn QuicDatagramDriver::on_datagram(
  self : QuicDatagramDriver,
  source : @types.Endpoint,
  packet : Bytes,
  now_ms : Int64,
) -> Result[Array[QuicDriverAction], QuicError] {
  self.count_received_datagram(source, packet)
  self.on_packet(source, packet, now_ms)
}

///|
fn QuicDatagramDriver::receive_negotiation_packet(
  self : QuicDatagramDriver,
  source : @types.Endpoint,
  packet : Bytes,
  now_ms : Int64,
) -> Result[Array[QuicDriverAction], QuicError] {
  if self.state() == Closed ||
    self.state() == Draining ||
    source != self.path.active() {
    return Ok([PacketIgnored])
  }
  if now_ms < 0L {
    return Err(InvalidPacket("QUIC clock cannot be negative"))
  }
  if !packet.is_empty() && (packet[0].to_int() & 0x80) != 0 {
    match quic_long_header_connection_ids(packet) {
      Ok((version, destination, peer_source)) => {
        if version == QUIC_VERSION_NEGOTIATION {
          return self.receive_version_negotiation(
            packet, destination, peer_source,
          )
        }
        if version != QUIC_VERSION_1 {
          if self.role == Server && packet.length() >= 1200 {
            let response = match
              quic_build_version_negotiation_packet(peer_source, destination, [
                QUIC_VERSION_1,
              ]) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            match self.check_amplification(source, response.length()) {
              Ok(_) => {
                self.count_sent_datagram(source, response.length())
                return Ok([SendDatagram(source, response)])
              }
              Err(error) => return Err(error)
            }
          }
          return Ok([PacketIgnored])
        }
        if ((packet[0].to_int() >> 4) & 0x03) == 3 {
          let (header, _) = match quic_decode_packet_header(packet) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          match header {
            Retry(retry) =>
              return self.receive_retry(source, packet, retry, now_ms)
            _ => return Err(InvalidPacket("invalid Retry packet"))
          }
        }
        ignore(destination)
      }
      Err(error) => return Err(error)
    }
  }
  Ok([PacketIgnored])
}

///|
fn QuicDatagramDriver::receive_version_negotiation(
  self : QuicDatagramDriver,
  packet : Bytes,
  destination : ConnectionId,
  peer_source : ConnectionId,
) -> Result[Array[QuicDriverAction], QuicError] {
  if self.role != Client ||
    self.state() != Handshaking ||
    self.initial_receive_keys is None ||
    self.next_initial_packet == 0L ||
    self.initial_peer_id is Some(_) ||
    self.largest_handshake_received >= 0L ||
    self.retry_source is Some(_) ||
    destination != self.local_connection_id ||
    peer_source != self.original_destination {
    return Ok([PacketIgnored])
  }
  let (header, _) = match quic_decode_packet_header(packet) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match header {
    VersionNegotiation(value) => {
      if value.versions.contains(QUIC_VERSION_1) {
        return Ok([PacketIgnored])
      }
      self.connection.state = Closed
      Err(VersionNegotiation(value.versions))
    }
    _ => Err(InvalidPacket("version zero did not encode Version Negotiation"))
  }
}

///|
fn QuicDatagramDriver::receive_retry(
  self : QuicDatagramDriver,
  source : @types.Endpoint,
  packet : Bytes,
  retry : RetryPacket,
  now_ms : Int64,
) -> Result[Array[QuicDriverAction], QuicError] {
  if self.role != Client ||
    self.state() != Handshaking ||
    self.initial_receive_keys is None ||
    self.next_initial_packet == 0L ||
    self.initial_peer_id is Some(_) ||
    self.largest_handshake_received >= 0L ||
    source != self.path.active() {
    return Ok([PacketIgnored])
  }
  if retry.version != QUIC_VERSION_1 ||
    retry.destination != self.local_connection_id ||
    retry.source == self.original_destination ||
    retry.source.bytes().is_empty() ||
    retry.token.is_empty() ||
    retry.token.length() > retry_token_max_length ||
    self.retry_source is Some(_) {
    return Ok([PacketIgnored])
  }
  if packet.length() < 16 {
    return Err(NeedMoreInput)
  }
  let without_tag = packet[:packet.length() - 16].to_owned()
  match
    @tls.quic_verify_retry_integrity(
      self.original_destination.bytes(),
      without_tag,
      retry.integrity_tag,
    ) {
    Ok(_) => ()
    Err(_) => return Ok([PacketIgnored])
  }
  let keys = match quic_initial_packet_keys(retry.source) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  self.initial_send_keys = Some(keys.0)
  self.initial_receive_keys = Some(keys.1)
  self.initial_destination = retry.source
  self.peer_connection_id = retry.source
  self.initial_token = retry.token
  self.retry_source = Some(retry.source)
  // RFC 9000 section 17.2.5.3 forbids reusing packet numbers after Retry.
  // Reset congestion/loss bookkeeping while preserving the next number and
  // the original TLS transcript. Previously sent CRYPTO is retransmitted at
  // its original byte offset under the new Initial keys and token.
  self.recovery = match
    QuicRecovery::new(config=self.recovery.config, now_ms~) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  for entry in self.retransmissions {
    entry.pending = true
  }
  self.initial_peer_id = None
  self.largest_initial_received = -1L
  self.seen_initial = []
  let output = [RetryReceived(retry.source)]
  match self.flush_pending_retransmissions(Initial, now_ms) {
    Ok(actions) => {
      output.append(actions)
      Ok(output)
    }
    Err(error) => Err(error)
  }
}

///|
fn QuicDatagramDriver::on_packet(
  self : QuicDatagramDriver,
  source : @types.Endpoint,
  packet : Bytes,
  now_ms : Int64,
) -> Result[Array[QuicDriverAction], QuicError] {
  if self.state() == Closed || self.state() == Draining {
    return Ok([PacketIgnored])
  }
  if packet.is_empty() ||
    packet.length() > self.transport_params.max_udp_payload_size {
    return Err(
      LimitExceeded("QUIC datagram", self.transport_params.max_udp_payload_size),
    )
  }
  if now_ms < 0L {
    return Err(InvalidPacket("QUIC clock cannot be negative"))
  }
  let candidate_path = source != self.path.active()
  if candidate_path && self.path.candidate() != Some(source) {
    return Err(InvalidPacket("packet arrived on an unvalidated path"))
  }
  let first = packet[0].to_int()
  let long_header = (first & 0x80) != 0
  if long_header &&
    packet.length() >= 5 &&
    (packet_version(packet) != QUIC_VERSION_1 || ((first >> 4) & 3) == 3) {
    if candidate_path {
      return Ok([PacketIgnored])
    }
    return self.receive_negotiation_packet(source, packet, now_ms)
  }
  let (space, opened, source_connection_id, advance_keys) = if long_header {
    if candidate_path {
      return Err(
        InvalidPacket("path validation requires an application packet"),
      )
    }
    let fields = match quic_long_header_fields(packet) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let (version, destination, source_id, packet_type, packet_number_offset, _) = fields
    let initial_destination = self.role == Server &&
      packet_type == 0 &&
      destination == self.initial_destination
    if version != QUIC_VERSION_1 ||
      (destination != self.local_connection_id && !initial_destination) {
      return Err(
        InvalidPacket(
          "long-header version or destination does not match this QUIC connection",
        ),
      )
    }
    let initial_token : Bytes? = if packet_type == 0 {
      match quic_decode_packet_header(packet) {
        Ok((Initial(value), _)) => Some(value.token)
        _ => None
      }
    } else {
      None
    }
    // Post-Retry servers are constructed only from a validated context. Every
    // later Initial must preserve the exact token and its endpoint/CID binding;
    // this check is independent of whether the issuer is retained by the driver.
    if self.role == Server && packet_type == 0 {
      match self.retry_context {
        Some(context) =>
          if initial_token != Some(context.token) ||
            !context.matches(
              source,
              self.original_destination,
              destination,
              source_id,
            ) {
            return Ok([PacketIgnored])
          }
        None =>
          match initial_token {
            Some(token) if !token.is_empty() => return Ok([PacketIgnored])
            _ => ()
          }
      }
    }
    let space = match quic_driver_packet_space(packet_type) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if (space == Initial && self.initial_receive_keys is None) ||
      (
        space == Handshake &&
        self.handshake_receive_keys is None &&
        self.key_update.confirmed
      ) {
      return Ok([PacketIgnored])
    }
    let keys = match self.quic_driver_space_keys(space, false) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let opened = match
      quic_open_packet_with_keys(
        keys,
        packet,
        packet_number_offset,
        self.quic_driver_largest(space),
        true,
      ) {
      Ok(value) => value
      Err(error) => return Err(self.record_authentication_failure(error))
    }
    (space, opened, Some(source_id), false)
  } else {
    let space = Application
    let offset = 1 + self.local_connection_id.bytes().length()
    if packet.length() <= offset {
      return Err(NeedMoreInput)
    }
    if packet[1:offset].to_owned() != self.local_connection_id.bytes() {
      return Err(
        InvalidPacket(
          "short-header destination does not match this QUIC connection",
        ),
      )
    }
    let (opened, advance) = match
      self.open_application_packet(packet, offset, now_ms) {
      Ok(value) => value
      Err(error) => return Err(self.record_authentication_failure(error))
    }
    (space, opened, None, advance)
  }
  if space == Application && self.state() != Established {
    return Err(
      Unsupported("application packets require an established connection"),
    )
  }
  if self.quic_driver_seen(space, opened.packet_number()) {
    return Ok([PacketIgnored])
  }
  let frames = match quic_decode_frames(opened.payload(), limits=self.limits) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match quic_validate_frames_for_space(space, frames) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  // This driver issues only its initial local CID (sequence zero) and accepts
  // packets only for that CID. A peer cannot retire its own NEW_CONNECTION_ID
  // entries, and retiring the CID used by this packet is a protocol violation.
  // Check the complete packet before an earlier NEW_CONNECTION_ID can mutate
  // the peer namespace.
  for frame in frames {
    if frame is RetireConnectionId(sequence) {
      return Err(
        Protocol(
          0x0aL,
          if sequence == 0L {
            "cannot retire the destination connection ID of this packet"
          } else {
            "peer retired a connection ID that was never issued locally"
          },
        ),
      )
    }
  }
  if frames.contains(HandshakeDone) &&
    (self.role != Client || self.state() != Established) {
    return Err(
      InvalidFrame(
        "HANDSHAKE_DONE is only valid from the server after TLS completion",
      ),
    )
  }
  if candidate_path {
    // A candidate path cannot affect connection, recovery, or stream state
    // before it proves receipt of the challenge. Validate the entire packet
    // before processing any ACK or other side effects.
    let mut has_response = false
    for frame in frames {
      match frame {
        Padding | Ack(_) => ()
        PathResponse(data) if self.path.matches_response(data) =>
          has_response = true
        _ => return Err(InvalidPacket("candidate path has not been validated"))
      }
    }
    if !has_response {
      return Err(
        InvalidPacket("candidate path requires a matching PATH_RESPONSE"),
      )
    }
  }
  let has_path_challenge = frames.any(fn(frame) { frame is PathChallenge(_) })
  if has_path_challenge {
    // PATH_RESPONSE needs recovery capacity. Process authenticated ACKs first
    // so a packet can release the slot its own response needs, regardless of
    // frame order. A deferred packet must not commit CID/stream state or be
    // marked seen; the peer can retry it after capacity returns.
    for frame in frames {
      if frame is Ack(ack) {
        match self.apply_recovery_ack(space, ack, now_ms) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
      }
    }
    if self.recovery.sent.length() >= self.recovery.config.max_tracked_packets {
      return Ok([PacketIgnored])
    }
  }
  if source_connection_id is Some(id) {
    if self.initial_peer_id is Some(expected) && id != expected {
      return Err(InvalidPacket("peer changed its Initial source connection ID"))
    }
    if space == Initial && self.initial_peer_id is None {
      self.initial_peer_id = Some(id)
    }
    if self.state() == Handshaking {
      self.peer_connection_id = id
    }
  }
  if space == Handshake && source == self.active_budget.endpoint {
    self.active_budget.validated = true
    if self.role == Server {
      self.discard_packet_space(Initial)
    }
  }
  if advance_keys {
    match self.advance_receive_keys(opened.packet_number(), now_ms) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  self.quic_driver_mark_seen(space, opened.packet_number())
  match self.recovery.on_receive(now_ms) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let actions : Array[QuicDriverAction] = []
  let responses : Array[QuicFrame] = []
  let mut ack_eliciting = false
  for frame in frames {
    match frame {
      Padding | Ack(_) => ()
      _ => ack_eliciting = true
    }
    match frame {
      Ack(ack) => {
        if !has_path_challenge {
          match self.apply_recovery_ack(space, ack, now_ms) {
            Ok(_) => ()
            Err(error) => return Err(error)
          }
        }
        let connection_actions = match self.connection.receive_frame(Ack(ack)) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let generated = match
          quic_driver_append_connection_actions(
            actions, connection_actions, space,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        responses.append(generated)
      }
      Crypto(offset, data) => {
        let output_start = match space {
          Initial => self.crypto_initial.next_offset()
          Handshake => self.crypto_handshake.next_offset()
          Application => self.crypto_application.next_offset()
        }
        let chunks = match space {
          Initial => self.crypto_initial.feed(offset, data)
          Handshake => self.crypto_handshake.feed(offset, data)
          Application => self.crypto_application.feed(offset, data)
        }
        match chunks {
          Ok(values) => {
            // The action carries the CRYPTO stream offset, not the enclosing
            // packet number.  A TLS consumer needs this offset to preserve
            // handshake ordering across packet loss and reordering.
            let mut chunk_offset = output_start
            for value in values {
              actions.push(CryptoData(space, chunk_offset, value))
              chunk_offset += value.length().to_int64()
            }
          }
          Err(error) => return Err(error)
        }
      }
      HandshakeDone => {
        if self.role != Client || self.state() != Established {
          return Err(
            InvalidFrame(
              "HANDSHAKE_DONE is only valid from the server after TLS completion",
            ),
          )
        }
        self.key_update.confirmed = true
        self.discard_packet_space(Handshake)
      }
      PathChallenge(data) => responses.push(PathResponse(data))
      PathResponse(data) =>
        match self.path.on_response(source, data) {
          Ok(_) => {
            if self.candidate_budget is Some(budget) {
              budget.validated = true
              self.active_budget = budget
              self.candidate_budget = None
            }
            self.discard_path_challenges()
            actions.push(PathValidated(self.path.active()))
          }
          Err(error) => return Err(error)
        }
      NewConnectionId(sequence, retire_prior_to, id, token) =>
        match
          self.receive_peer_connection_id(sequence, retire_prior_to, id, token) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
      _ => {
        let connection_actions = match self.connection.receive_frame(frame) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let generated = match
          quic_driver_append_connection_actions(
            actions, connection_actions, space,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        responses.append(generated)
      }
    }
  }
  if ack_eliciting {
    let range = match
      AckRange::new(opened.packet_number(), opened.packet_number()) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let ack = match AckFrame::new(opened.packet_number(), 0L, [range]) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    responses.push(Ack(ack))
  }
  // Application control frames must remain pending while replying to delayed
  // Initial/Handshake packets whose keys have not yet been discarded.
  // A retirement makes an ACK-only reply tracked and retransmittable. Keep it
  // pending when either queue is full so the ACK can still be sent.
  let retirement_count = if space == Application &&
    self.retransmissions.length() < self.max_retransmissions &&
    self.recovery.sent.length() < self.recovery.config.max_tracked_packets {
    self.append_pending_retirements(responses)
  } else {
    0
  }
  if !responses.is_empty() && self.state() != Closed && self.state() != Draining {
    match
      self.send_frames_internal_to(
        space,
        responses,
        now_ms,
        false,
        None,
        source,
      ) {
      Ok(value) => {
        self.consume_pending_retirements(retirement_count)
        actions.push(value)
      }
      Err(AmplificationBlocked) | Err(FlowControl(0L, _)) => ()
      Err(error) => return Err(error)
    }
  }
  if self.state() != Closed && self.state() != Draining {
    let retransmissions = match
      self.flush_pending_retransmissions(space, now_ms) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    actions.append(retransmissions)
  }
  Ok(actions)
}
