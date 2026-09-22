///|
/// Events emitted by the QUIC datagram driver.  The driver owns packet
/// protection, packet-number spaces, recovery and connection bookkeeping, but
/// leaves UDP I/O to the `DatagramSocket` capability.
pub(all) enum QuicDriverAction {
  SendDatagram(@transport.Endpoint, Bytes)
  StreamData(Int64, Bytes, Bool)
  StreamReset(Int64, Int64)
  CryptoData(PacketNumberSpace, Int64, Bytes)
  PathValidated(@transport.Endpoint)
  ConnectionClosed(Int64, String)
  PacketIgnored
} derive(Eq, Debug)

///|
pub(all) enum QuicDriverState {
  Handshaking
  Established
  Draining
  Closed
} derive(Eq, Debug)

///|
/// Frame payload retained beside recovery metadata.  QUIC acknowledgements
/// identify packets, while retransmission needs the original frame sequence.
struct QuicRetransmission {
  space : PacketNumberSpace
  number : Int64
  frames : Array[QuicFrame]
  mut pending : Bool
}

///|
/// A bounded CRYPTO reassembler.  TLS handshake bytes are carried in QUIC
/// CRYPTO frames and may arrive fragmented, duplicated, or out of order.  The
/// reassembler only releases contiguous bytes, so a TLS facade never has to
/// guess whether a gap is a record boundary.
pub struct QuicCryptoReassembler {
  mut next_offset : Int64
  mut segments : Array[(Int64, Bytes)]
  delivered : Array[Byte]
  max_bytes : Int
} derive(Eq, Debug)

///|
pub fn QuicCryptoReassembler::new(
  max_bytes? : Int = 1024 * 1024,
) -> Result[QuicCryptoReassembler, QuicError] {
  if max_bytes < 0 {
    return Err(LimitExceeded("CRYPTO reassembly", max_bytes))
  }
  Ok({ next_offset: 0L, segments: [], delivered: [], max_bytes, })
}

///|
pub fn QuicCryptoReassembler::next_offset(
  self : QuicCryptoReassembler,
) -> Int64 {
  self.next_offset
}

///|
fn crypto_segment_end(offset : Int64, data : Bytes) -> Result[Int64, QuicError] {
  if offset < 0L || data.length() > @int.MAX_VALUE {
    return Err(InvalidPacket("invalid CRYPTO range"))
  }
  let length = data.length().to_int64()
  if offset > QUIC_MAX_VARINT - length {
    return Err(VarIntOverflow)
  }
  Ok(offset + length)
}

///|
/// Feeds a CRYPTO range and returns newly contiguous chunks.  Empty ranges do
/// not generate events and overlapping bytes are accepted only when their
/// contents agree; conflicting retransmissions are authentication/protocol
/// failures rather than silently replacing handshake state.
pub fn QuicCryptoReassembler::feed(
  self : QuicCryptoReassembler,
  offset : Int64,
  data : Bytes,
) -> Result[Array[Bytes], QuicError] {
  self.feed_bounded(offset, data, "CRYPTO reassembly")
}

///|
fn QuicCryptoReassembler::feed_bounded(
  self : QuicCryptoReassembler,
  offset : Int64,
  data : Bytes,
  limit_name : String,
) -> Result[Array[Bytes], QuicError] {
  let mut offset = offset
  let mut data = data
  let mut end = match crypto_segment_end(offset, data) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if end > self.max_bytes.to_int64() {
    return Err(LimitExceeded(limit_name, self.max_bytes))
  }
  if data.is_empty() {
    return Ok([])
  }
  if offset < self.next_offset {
    let overlap_end = end.min(self.next_offset)
    for position in offset..<overlap_end {
      let history_index = position.to_int()
      if history_index >= self.delivered.length() ||
        data[(position - offset).to_int()] != self.delivered[history_index] {
        return Err(Protocol(0x0aL, "conflicting retransmitted stream bytes"))
      }
    }
    if end <= self.next_offset {
      return Ok([])
    }
    let trim = (self.next_offset - offset).to_int()
    data = data[trim:].to_owned()
    offset = self.next_offset
    end = offset + data.length().to_int64()
  }
  // Compare every existing overlap before coalescing.  This is deliberately
  // byte based; handshake messages are not assumed to be aligned to frames.
  for existing in self.segments {
    let existing_end = existing.0 + existing.1.length().to_int64()
    let overlap_start = offset.max(existing.0)
    let overlap_end = end.min(existing_end)
    if overlap_start < overlap_end {
      for position in overlap_start..<overlap_end {
        let incoming_byte = data[(position - offset).to_int()]
        let existing_byte = existing.1[(position - existing.0).to_int()]
        if incoming_byte != existing_byte {
          return Err(Protocol(0x0aL, "conflicting retransmitted stream bytes"))
        }
      }
    }
  }
  self.segments.push((offset, data))
  let segment_count = self.segments.length()
  for left in 0..<segment_count {
    for right in (left + 1)..<segment_count {
      if self.segments[right].0 < self.segments[left].0 {
        let temporary = self.segments[left]
        self.segments[left] = self.segments[right]
        self.segments[right] = temporary
      }
    }
  }
  // Coalesce adjacent ranges, retaining the first copy for overlap bytes.
  let merged : Array[(Int64, Bytes)] = []
  for segment in self.segments {
    let segment_end = segment.0 + segment.1.length().to_int64()
    if merged.is_empty() {
      merged.push(segment)
      continue
    }
    let last_index = merged.length() - 1
    let last = merged[last_index]
    let last_end = last.0 + last.1.length().to_int64()
    if segment.0 > last_end {
      merged.push(segment)
    } else if segment_end > last_end {
      let suffix_start = (last_end - segment.0).to_int()
      let suffix = segment.1[suffix_start:].to_owned()
      let combined = quic_driver_join([last.1, suffix])
      merged[last_index] = (last.0, combined)
    }
  }
  self.segments = merged
  let output : Array[Bytes] = []
  while !self.segments.is_empty() && self.segments[0].0 <= self.next_offset {
    let segment = self.segments[0]
    let segment_end = segment.0 + segment.1.length().to_int64()
    if segment_end <= self.next_offset {
      self.segments.remove(0) |> ignore
      continue
    }
    let start = (self.next_offset - segment.0).to_int()
    let chunk = segment.1[start:].to_owned()
    self.next_offset = segment_end
    self.segments.remove(0) |> ignore
    if !chunk.is_empty() {
      for byte in chunk {
        self.delivered.push(byte)
      }
      output.push(chunk)
    }
  }
  Ok(output)
}

///|
fn quic_driver_join(parts : Array[Bytes]) -> Bytes {
  let mut length = 0
  for part in parts {
    length += part.length()
  }
  let output = FixedArray::make(length, b'\x00')
  let mut cursor = 0
  for part in parts {
    for byte in part {
      output[cursor] = byte
      cursor += 1
    }
  }
  output.unsafe_reinterpret_as_bytes()
}

///|
pub struct QuicDatagramDriver {
  role : QuicRole
  endpoint : @transport.Endpoint
  limits : QuicLimits
  transport_params : QuicTransportParams
  connection : QuicConnection
  local_connection_id : ConnectionId
  mut peer_connection_id : ConnectionId
  initial_send_keys : @tls.QuicPacketKeys
  initial_receive_keys : @tls.QuicPacketKeys
  mut handshake_send_keys : @tls.QuicPacketKeys?
  mut handshake_receive_keys : @tls.QuicPacketKeys?
  mut application_send_keys : @tls.QuicPacketKeys?
  mut application_receive_keys : @tls.QuicPacketKeys?
  recovery : QuicRecovery
  path : QuicPathManager
  connection_ids : QuicConnectionIdManager
  mut state : QuicDriverState
  mut largest_initial_received : Int64
  mut largest_handshake_received : Int64
  mut largest_application_received : Int64
  mut next_initial_packet : Int64
  mut next_handshake_packet : Int64
  mut next_application_packet : Int64
  seen_initial : Array[Int64]
  seen_handshake : Array[Int64]
  seen_application : Array[Int64]
  crypto_initial : QuicCryptoReassembler
  crypto_handshake : QuicCryptoReassembler
  crypto_application : QuicCryptoReassembler
  retransmissions : Array[QuicRetransmission]
  max_retransmissions : Int
  authorize_endpoint : (@transport.Endpoint, @transport.PolicyOperation) -> Result[
    Unit,
    @transport.PolicyError,
  ]
}

///|
pub fn QuicDatagramDriver::new(
  role : QuicRole,
  endpoint : @transport.Endpoint,
  initial_destination : ConnectionId,
  local_connection_id : ConnectionId,
  peer_connection_id : ConnectionId,
  limits? : QuicLimits = QuicLimits::defaults(),
  transport_params? : QuicTransportParams = QuicTransportParams::defaults(),
  recovery_config? : QuicRecoveryConfig = QuicRecoveryConfig::defaults(),
  now_ms? : Int64 = 0L,
  authorize? : (@transport.Endpoint, @transport.PolicyOperation) -> Result[
    Unit,
    @transport.PolicyError,
  ] = fn(_, _) { Ok(()) },
) -> Result[QuicDatagramDriver, QuicError] {
  match authorize(endpoint, QuicEndpoint) {
    Ok(_) => ()
    Err(error) => return Err(Policy(error))
  }
  match limits.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match transport_params.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let connection = match QuicConnection::new(role, limits~, transport_params~) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let recovery = match QuicRecovery::new(config=recovery_config, now_ms~) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let initial_keys = match quic_initial_packet_keys(initial_destination) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let send_keys = if role == Client { initial_keys.0 } else { initial_keys.1 }
  let receive_keys = if role == Client {
    initial_keys.1
  } else {
    initial_keys.0
  }
  let path = QuicPathManager::new(endpoint)
  let connection_ids = match
    QuicConnectionIdManager::new(
      local_connection_id,
      max_active=transport_params.active_connection_id_limit.to_int(),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let initial_crypto = match
    QuicCryptoReassembler::new(max_bytes=limits.max_crypto_bytes) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let handshake_crypto = match
    QuicCryptoReassembler::new(max_bytes=limits.max_crypto_bytes) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let application_crypto = match
    QuicCryptoReassembler::new(max_bytes=limits.max_crypto_bytes) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    role,
    endpoint,
    limits,
    transport_params,
    connection,
    local_connection_id,
    peer_connection_id,
    initial_send_keys: send_keys,
    initial_receive_keys: receive_keys,
    handshake_send_keys: None,
    handshake_receive_keys: None,
    application_send_keys: None,
    application_receive_keys: None,
    recovery,
    path,
    connection_ids,
    state: Handshaking,
    largest_initial_received: -1L,
    largest_handshake_received: -1L,
    largest_application_received: -1L,
    next_initial_packet: 0L,
    next_handshake_packet: 0L,
    next_application_packet: 0L,
    seen_initial: [],
    seen_handshake: [],
    seen_application: [],
    crypto_initial: initial_crypto,
    crypto_handshake: handshake_crypto,
    crypto_application: application_crypto,
    retransmissions: [],
    max_retransmissions: recovery_config.max_tracked_packets,
    authorize_endpoint: authorize,
  })
}

///|
pub fn QuicDatagramDriver::state(self : QuicDatagramDriver) -> QuicDriverState {
  self.state
}

///|
pub fn QuicDatagramDriver::endpoint(
  self : QuicDatagramDriver,
) -> @transport.Endpoint {
  self.endpoint
}

///|
/// Returns the current path validation state without exposing the manager.
pub fn QuicDatagramDriver::path_status(
  self : QuicDatagramDriver,
) -> QuicPathStatus {
  self.path.status()
}

///|
pub fn QuicDatagramDriver::connection(
  self : QuicDatagramDriver,
) -> QuicConnection {
  self.connection
}

///|
pub fn QuicDatagramDriver::local_connection_id(
  self : QuicDatagramDriver,
) -> ConnectionId {
  self.local_connection_id
}

///|
pub fn QuicDatagramDriver::peer_connection_id(
  self : QuicDatagramDriver,
) -> ConnectionId {
  self.peer_connection_id
}

///|
pub fn QuicDatagramDriver::install_handshake_keys(
  self : QuicDatagramDriver,
  send : @tls.QuicPacketKeys,
  receive : @tls.QuicPacketKeys,
) -> Result[Unit, QuicError] {
  guard self.state != Closed else {
    return Err(ConnectionClosed(0L, "connection is closed"))
  }
  self.handshake_send_keys = Some(send)
  self.handshake_receive_keys = Some(receive)
  Ok(())
}

///|
pub fn QuicDatagramDriver::install_application_keys(
  self : QuicDatagramDriver,
  send : @tls.QuicPacketKeys,
  receive : @tls.QuicPacketKeys,
) -> Result[Unit, QuicError] {
  guard self.state != Closed else {
    return Err(ConnectionClosed(0L, "connection is closed"))
  }
  self.application_send_keys = Some(send)
  self.application_receive_keys = Some(receive)
  Ok(())
}

///|
pub fn QuicDatagramDriver::establish(
  self : QuicDatagramDriver,
) -> Result[Unit, QuicError] {
  if self.application_send_keys is None || self.application_receive_keys is None {
    return Err(
      Unsupported("cannot establish before application keys are installed"),
    )
  }
  match self.connection.establish() {
    Ok(_) => {
      self.state = Established
      Ok(())
    }
    Err(error) => Err(error)
  }
}

///|
fn QuicDatagramDriver::quic_driver_space_keys(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
  sending : Bool,
) -> Result[@tls.QuicPacketKeys, QuicError] {
  match (space, sending) {
    (Initial, true) => Ok(self.initial_send_keys)
    (Initial, false) => Ok(self.initial_receive_keys)
    (Handshake, true) =>
      match self.handshake_send_keys {
        Some(keys) => Ok(keys)
        None => Err(Unsupported("Handshake keys are not installed"))
      }
    (Handshake, false) =>
      match self.handshake_receive_keys {
        Some(keys) => Ok(keys)
        None => Err(Unsupported("Handshake keys are not installed"))
      }
    (Application, true) =>
      match self.application_send_keys {
        Some(keys) => Ok(keys)
        None => Err(Unsupported("application keys are not installed"))
      }
    (Application, false) =>
      match self.application_receive_keys {
        Some(keys) => Ok(keys)
        None => Err(Unsupported("application keys are not installed"))
      }
  }
}

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
        packet_number_length,
        max_datagram_size: self.transport_params.max_udp_payload_size,
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
          max_datagram_size=self.transport_params.max_udp_payload_size,
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
fn QuicDatagramDriver::send_frames_internal(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
  frames : Array[QuicFrame],
  now_ms : Int64,
  congestion_exempt : Bool,
  replacement_number : Int64?,
) -> Result[QuicDriverAction, QuicError] {
  if now_ms < 0L {
    return Err(InvalidPacket("QUIC clock cannot be negative"))
  }
  guard self.state != Closed else {
    return Err(ConnectionClosed(0L, "connection is closed"))
  }
  if space == Application && self.state != Established {
    return Err(
      Unsupported("application packets require an established connection"),
    )
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
  let payload = match quic_encode_frames(frames, limits=self.limits) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if payload.is_empty() {
    return Err(InvalidFrame("cannot send an empty QUIC packet"))
  }
  let (packet_number, packet) = match
    self.quic_driver_build_packet(space, payload) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let packet_size = packet.length()
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
      self.quic_driver_commit_number(space)
      if retransmittable {
        match replacement_number {
          Some(number) =>
            if self.take_retransmission(space, number) is None {
              // The entry was checked before recovery state was mutated. This
              // branch is unreachable without internal state corruption.
              self.state = Closed
              return Err(InvalidPacket("QUIC retransmission state changed"))
            }
          None => ()
        }
        self.queue_retransmission(space, packet_number, frames)
      }
      Ok(SendDatagram(self.endpoint, packet))
    }
    Err(error) => Err(error)
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
fn quic_frame_is_ack_eliciting(frame : QuicFrame) -> Bool {
  match frame {
    Ack(_) | Padding => false
    _ => true
  }
}

///|
fn quic_frame_is_retransmittable(frame : QuicFrame) -> Bool {
  match frame {
    Ack(_) | Padding | PathResponse(_) | Datagram(_) => false
    _ => true
  }
}

///|
fn quic_frames_are_retransmittable(frames : Array[QuicFrame]) -> Bool {
  frames.any(quic_frame_is_retransmittable)
}

///|
fn QuicDatagramDriver::take_retransmission(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
  number : Int64,
) -> Array[QuicFrame]? {
  let mut index = self.retransmissions.length() - 1
  while index >= 0 {
    let entry = self.retransmissions[index]
    if entry.space == space && entry.number == number {
      self.retransmissions.remove(index) |> ignore
      return Some(entry.frames)
    }
    index -= 1
  }
  None
}

///|
fn quic_ack_contains(ack : AckFrame, number : Int64) -> Bool {
  ack
  .ranges()
  .any(fn(range) { number >= range.smallest() && number <= range.largest() })
}

///|
fn QuicDatagramDriver::mark_retransmission_pending(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
  number : Int64,
) -> Unit {
  for entry in self.retransmissions {
    if entry.space == space && entry.number == number {
      entry.pending = true
      return
    }
  }
}

///|
fn QuicDatagramDriver::next_pending_retransmission(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
) -> (Int64, Array[QuicFrame])? {
  for entry in self.retransmissions {
    if entry.space == space && entry.pending {
      return Some((entry.number, entry.frames))
    }
  }
  None
}

///|
fn QuicDatagramDriver::flush_pending_retransmissions(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
  now_ms : Int64,
  congestion_exempt? : Bool = false,
) -> Result[Array[QuicDriverAction], QuicError] {
  let actions : Array[QuicDriverAction] = []
  while self.next_pending_retransmission(space) is Some((number, frames)) {
    match
      self.send_frames_internal(
        space,
        frames,
        now_ms,
        congestion_exempt,
        Some(number),
      ) {
      Ok(action) => actions.push(action)
      // Congestion backpressure is not a protocol failure. The retained entry
      // remains pending and can be sent after a later ACK or timer tick.
      Err(FlowControl(0L, _)) => break
      Err(error) => return Err(error)
    }
  }
  Ok(actions)
}

///|
/// Applies recovery notifications to the driver's retained frame payloads.
/// ACKed payloads are discarded and lost payloads are marked pending. They are
/// removed only after a replacement packet has been accepted by recovery.
fn QuicDatagramDriver::apply_recovery_ack(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
  ack : AckFrame,
  now_ms : Int64,
) -> Result[Unit, QuicError] {
  let events = match self.recovery.on_ack(space, ack, now_ms) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let lost = match self.recovery.detect_loss(space, now_ms) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  ignore(events)
  // A late ACK can arrive after a packet was declared lost but before its
  // retained frames could be retransmitted. Remove every acknowledged copy,
  // not only packets still present in the recovery engine.
  let mut retained_index = self.retransmissions.length() - 1
  while retained_index >= 0 {
    let entry = self.retransmissions[retained_index]
    if entry.space == space && quic_ack_contains(ack, entry.number) {
      self.retransmissions.remove(retained_index) |> ignore
    }
    retained_index -= 1
  }
  for event in lost {
    match event {
      PacketLost(number, event_space, bytes) => {
        ignore(bytes)
        self.mark_retransmission_pending(event_space, number)
      }
      _ => ()
    }
  }
  Ok(())
}

///|
fn QuicDatagramDriver::queue_retransmission(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
  number : Int64,
  frames : Array[QuicFrame],
) -> Unit {
  if quic_frames_are_retransmittable(frames) {
    let retained : Array[QuicFrame] = []
    for frame in frames {
      if quic_frame_is_retransmittable(frame) {
        retained.push(frame)
      }
    }
    self.retransmissions.push({
      space,
      number,
      frames: retained,
      pending: false,
    })
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
  source : @transport.Endpoint,
  packet : Bytes,
  now_ms : Int64,
) -> Result[Array[QuicDriverAction], QuicError] {
  if packet.is_empty() ||
    packet.length() > self.transport_params.max_udp_payload_size {
    return Err(
      LimitExceeded("QUIC datagram", self.transport_params.max_udp_payload_size),
    )
  }
  if now_ms < 0L {
    return Err(InvalidPacket("QUIC clock cannot be negative"))
  }
  if source != self.path.active() {
    return Err(InvalidPacket("packet arrived on an unvalidated path"))
  }
  let first = packet[0].to_int()
  let long_header = (first & 0x80) != 0
  let (space, opened) = if long_header {
    let fields = match quic_long_header_fields(packet) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let (version, destination, source_id, packet_type, packet_number_offset, _) = fields
    if version != QUIC_VERSION_1 || destination != self.local_connection_id {
      return Err(InvalidPacket("packet is for another QUIC connection"))
    }
    let space = match quic_driver_packet_space(packet_type) {
      Ok(value) => value
      Err(error) => return Err(error)
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
      Err(error) => return Err(error)
    }
    self.peer_connection_id = source_id
    (space, opened)
  } else {
    let space = Application
    let offset = 1 + self.local_connection_id.bytes().length()
    if packet.length() <= offset {
      return Err(NeedMoreInput)
    }
    let keys = match self.quic_driver_space_keys(space, false) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let opened = match
      quic_open_packet_with_keys(
        keys,
        packet,
        offset,
        self.quic_driver_largest(space),
        false,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    (space, opened)
  }
  if space == Application && self.state != Established {
    return Err(
      Unsupported("application packets require an established connection"),
    )
  }
  if self.quic_driver_seen(space, opened.packet_number()) {
    return Ok([PacketIgnored])
  }
  self.quic_driver_mark_seen(space, opened.packet_number())
  match self.recovery.on_receive(now_ms) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let frames = match quic_decode_frames(opened.payload(), limits=self.limits) {
    Ok(value) => value
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
        match self.apply_recovery_ack(space, ack, now_ms) {
          Ok(_) => ()
          Err(error) => return Err(error)
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
      PathChallenge(data) => responses.push(PathResponse(data))
      PathResponse(data) =>
        match self.path.on_response(source, data) {
          Ok(_) => actions.push(PathValidated(source))
          Err(error) => return Err(error)
        }
      NewConnectionId(sequence, retire_prior_to, id, token) =>
        match
          self.connection_ids.receive(sequence, retire_prior_to, id, token) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
      RetireConnectionId(sequence) =>
        match self.connection_ids.retire(sequence) {
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
  if !responses.is_empty() && self.state != Closed {
    let send = match self.send_frames(space, responses, now_ms) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    actions.push(send)
  }
  if self.state != Closed {
    let retransmissions = match
      self.flush_pending_retransmissions(space, now_ms) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    actions.append(retransmissions)
  }
  Ok(actions)
}

///|
pub fn QuicDatagramDriver::begin_path_validation(
  self : QuicDatagramDriver,
  endpoint : @transport.Endpoint,
  challenge : Bytes,
) -> Result[Unit, QuicError] {
  match (self.authorize_endpoint)(endpoint, QuicEndpoint) {
    Ok(_) => ()
    Err(error) => return Err(Policy(error))
  }
  self.path.begin(endpoint, challenge)
}

///|
pub fn QuicDatagramDriver::poll(
  self : QuicDatagramDriver,
  now_ms : Int64,
) -> Result[Array[QuicDriverAction], QuicError] {
  let events = match self.recovery.poll(now_ms) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let output : Array[QuicDriverAction] = []
  for event in events {
    match event {
      IdleTimeout => {
        self.state = Closed
        output.push(ConnectionClosed(0L, "QUIC idle timeout"))
      }
      ProbeTimeout(space) => {
        let replacement : Int64? = match
          self.recovery.take_oldest_probe_packet(space) {
          Some(packet) => {
            self.mark_retransmission_pending(space, packet.number())
            match self.next_pending_retransmission(space) {
              Some((number, _)) if number == packet.number() => Some(number)
              _ => None
            }
          }
          None => None
        }
        let probe_frames = match replacement {
          Some(number) =>
            match self.next_pending_retransmission(space) {
              Some((pending_number, frames)) if pending_number == number =>
                frames
              _ => [Ping]
            }
          None => [Ping]
        }
        let packet = match
          self.send_frames_internal(
            space, probe_frames, now_ms, true, replacement,
          ) {
          Ok(value) => value
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

///|
/// One capability-bound receive step.  It is intentionally separate from the
/// core so tests can drive `on_datagram` with deterministic byte arrays.
pub async fn[S : @transport.DatagramSocket] QuicDatagramDriver::receive_once(
  self : QuicDatagramDriver,
  socket : S,
  max_bytes : Int,
  now_ms : Int64,
) -> Result[Array[QuicDriverAction], QuicError] {
  let datagram = match socket.receive(max_bytes) {
    Ok(value) => value
    Err(error) => return Err(Transport(error))
  }
  self.on_datagram(datagram.endpoint(), datagram.payload(), now_ms)
}

///|
pub async fn[S : @transport.DatagramSocket] QuicDatagramDriver::send_action(
  self : QuicDatagramDriver,
  socket : S,
  action : QuicDriverAction,
) -> Result[Unit, QuicError] {
  ignore(self)
  match action {
    SendDatagram(endpoint, bytes) =>
      match socket.send(endpoint, bytes) {
        Ok(_) => Ok(())
        Err(error) => {
          self.state = Closed
          Err(Transport(error))
        }
      }
    _ => Ok(())
  }
}
