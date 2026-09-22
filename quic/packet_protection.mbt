///|
/// Result of removing QUIC header protection and opening an AEAD payload.
pub(all) struct QuicOpenedPacket {
  header : Bytes
  payload : Bytes
  packet_number : Int64
  packet_number_length : Int
  key_phase : Bool
}

///|
pub fn QuicOpenedPacket::header(self : QuicOpenedPacket) -> Bytes {
  self.header
}

///|
pub fn QuicOpenedPacket::payload(self : QuicOpenedPacket) -> Bytes {
  self.payload
}

///|
pub fn QuicOpenedPacket::packet_number(self : QuicOpenedPacket) -> Int64 {
  self.packet_number
}

///|
pub fn QuicOpenedPacket::packet_number_length(self : QuicOpenedPacket) -> Int {
  self.packet_number_length
}

///|
pub fn QuicOpenedPacket::key_phase(self : QuicOpenedPacket) -> Bool {
  self.key_phase
}

///|
/// Selects the Initial keys for a QUIC v1 endpoint. The returned key is the
/// directional key for `role`; the other direction is returned only through
/// `quic_initial_packet_keys` for connection setup code that needs both.
pub fn quic_initial_packet_key(
  destination_connection_id : ConnectionId,
  role : QuicRole,
) -> Result[@tls.QuicPacketKeys, QuicError] {
  let pair = match
    @tls.quic_v1_initial_keys(destination_connection_id.bytes()) {
    Ok(value) => value
    Err(_) => return Err(InvalidPacket("invalid Initial key input"))
  }
  Ok(if role == Client { pair.0 } else { pair.1 })
}

///|
/// Returns `(client_send_or_receive, server_send_or_receive)` Initial keys.
pub fn quic_initial_packet_keys(
  destination_connection_id : ConnectionId,
) -> Result[(@tls.QuicPacketKeys, @tls.QuicPacketKeys), QuicError] {
  match @tls.quic_v1_initial_keys(destination_connection_id.bytes()) {
    Ok(value) => Ok(value)
    Err(_) => Err(InvalidPacket("invalid Initial key input"))
  }
}

///|
fn quic_packet_number_limit(length : Int) -> Int64 {
  match length {
    1 => 0xffL
    2 => 0xffffL
    3 => 0xffffffL
    _ => 0xffffffffL
  }
}

///|
fn quic_packet_number_bytes(packet_number : Int64, length : Int) -> Bytes {
  let output = FixedArray::make(length, b'\x00')
  for index in 0..<length {
    let shift = (length - index - 1) * 8
    output[index] = ((packet_number >> shift) & 0xffL).to_byte()
  }
  output.unsafe_reinterpret_as_bytes()
}

///|
fn quic_join_bytes(parts : Array[Bytes]) -> Bytes {
  let mut length = 0
  for part in parts {
    length += part.length()
  }
  let output = FixedArray::make(length, b'\x00')
  let mut offset = 0
  for part in parts {
    for byte in part {
      output[offset] = byte
      offset += 1
    }
  }
  output.unsafe_reinterpret_as_bytes()
}

///|
/// Reconstructs a full packet number from the truncated wire value as defined
/// by RFC 9000 section 12.3. `largest_received` is -1 before the first packet.
pub fn quic_reconstruct_packet_number(
  truncated : Int64,
  packet_number_length : Int,
  largest_received : Int64,
) -> Result[Int64, QuicError] {
  if packet_number_length < 1 ||
    packet_number_length > 4 ||
    truncated < 0L ||
    truncated > quic_packet_number_limit(packet_number_length) ||
    largest_received < -1L {
    return Err(InvalidPacket("invalid packet number reconstruction input"))
  }
  let window = 1L << (packet_number_length * 8)
  let half_window = window / 2L
  let expected = largest_received + 1L
  if expected > QUIC_MAX_VARINT {
    return Err(InvalidPacket("packet number space exhausted"))
  }
  let base = expected / window * window
  let mut candidate = base + truncated
  if candidate <= expected - half_window &&
    candidate <= QUIC_MAX_VARINT - window {
    candidate += window
  } else if candidate > expected + half_window && candidate >= window {
    candidate -= window
  }
  if candidate < 0L || candidate > QUIC_MAX_VARINT {
    Err(InvalidPacket("reconstructed packet number out of range"))
  } else {
    Ok(candidate)
  }
}

///|
fn quic_copy_with_byte(input : Bytes, index : Int, value : Byte) -> Bytes {
  let output = input.to_array()
  output[index] = value
  Bytes::from_array(output)
}

///|
/// Finds the packet-number offset and protected payload length in a QUIC
/// long header without looking at protected low bits. This is required before
/// header protection can be removed.
pub fn quic_long_header_packet_layout(
  packet : Bytes,
) -> Result[(Int, Int64), QuicError] {
  if packet.length() < 7 || (packet[0].to_int() & 0x80) == 0 {
    return Err(InvalidPacket("not a QUIC long-header packet"))
  }
  if (packet[0].to_int() & 0x40) == 0 {
    return Err(InvalidPacket("QUIC fixed bit is not set"))
  }
  let packet_type = (packet[0].to_int() >> 4) & 0x03
  if packet_type == 3 {
    return Err(InvalidPacket("Retry packets have no packet number"))
  }
  let (destination, after_destination) = match take_connection_id(packet, 5) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  ignore(destination)
  let (_, after_source) = match take_connection_id(packet, after_destination) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut offset = after_source
  if packet_type == 0 {
    let (token_length, used) = match quic_decode_varint(packet[offset:]) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    offset += used
    let token_length = match varint_to_index(token_length.value()) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if token_length > packet.length() - offset {
      return Err(NeedMoreInput)
    }
    offset += token_length
  }
  let (payload_length, used) = match quic_decode_varint(packet[offset:]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  offset += used
  if payload_length.value() < 1L {
    return Err(InvalidPacket("QUIC payload length excludes packet number"))
  }
  Ok((offset, payload_length.value()))
}

///|
/// Returns the unprotected structural fields needed by a datagram driver.
/// The packet-number bits are intentionally omitted: they are covered by
/// header protection and must only be inspected after the sampling step.
pub fn quic_long_header_fields(
  packet : Bytes,
) -> Result[(Int, ConnectionId, ConnectionId, Int, Int, Int64), QuicError] {
  if packet.length() < 7 || (packet[0].to_int() & 0x80) == 0 {
    return Err(InvalidPacket("not a QUIC long-header packet"))
  }
  if (packet[0].to_int() & 0x40) == 0 {
    return Err(InvalidPacket("QUIC fixed bit is not set"))
  }
  let packet_type = (packet[0].to_int() >> 4) & 0x03
  if packet_type == 3 {
    return Err(InvalidPacket("Retry packets have no packet number"))
  }
  let version = (packet[1].to_int() << 24) |
    (packet[2].to_int() << 16) |
    (packet[3].to_int() << 8) |
    packet[4].to_int()
  let (destination, after_destination) = match take_connection_id(packet, 5) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (source, after_source) = match
    take_connection_id(packet, after_destination) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut offset = after_source
  if packet_type == 0 {
    let (token_length, used) = match quic_decode_varint(packet[offset:]) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    offset += used
    let token_length = match varint_to_index(token_length.value()) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if token_length > packet.length() - offset {
      return Err(NeedMoreInput)
    }
    offset += token_length
  }
  let (payload_length, used) = match quic_decode_varint(packet[offset:]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  offset += used
  if payload_length.value() < 1L {
    return Err(InvalidPacket("QUIC payload length excludes packet number"))
  }
  Ok(
    (version, destination, source, packet_type, offset, payload_length.value()),
  )
}

///|
/// Applies QUIC packet protection to an unprotected header prefix and payload.
/// `header_prefix` must end immediately before the truncated packet number;
/// its first byte's low two bits are replaced with the packet-number length.
/// The caller owns packet padding. QUIC's sample is taken from the resulting
/// ciphertext, so callers must provide enough payload for the sample to exist.
pub fn quic_protect_packet_with_keys(
  keys : @tls.QuicPacketKeys,
  header_prefix : Bytes,
  packet_number : Int64,
  packet_number_length : Int,
  payload : Bytes,
  long_header : Bool,
) -> Result[Bytes, QuicError] {
  if header_prefix.is_empty() ||
    packet_number_length < 1 ||
    packet_number_length > 4 ||
    packet_number < 0L ||
    packet_number > QUIC_MAX_VARINT {
    return Err(InvalidPacket("invalid packet protection input"))
  }
  let first = header_prefix[0].to_int()
  if (first & 0x40) == 0 {
    return Err(InvalidPacket("fixed bit is not set"))
  }
  if long_header && (first & 0x80) == 0 {
    return Err(InvalidPacket("long-header protection flag is missing"))
  }
  if !long_header && (first & 0x80) != 0 {
    return Err(InvalidPacket("short-header protection flag is set"))
  }
  if (long_header && (first & 0x0c) != 0) ||
    (!long_header && (first & 0x18) != 0) {
    return Err(InvalidPacket("reserved header bits are non-zero"))
  }
  let normalized_first = ((first & 0xfc) | (packet_number_length - 1)).to_byte()
  let normalized_prefix = quic_copy_with_byte(
    header_prefix, 0, normalized_first,
  )
  let packet_number_bytes = quic_packet_number_bytes(
    packet_number, packet_number_length,
  )
  let aad = quic_join_bytes([normalized_prefix, packet_number_bytes])
  let ciphertext = match keys.seal(packet_number, aad, payload) {
    Ok(value) => value
    Err(_) => return Err(InvalidPacket("packet payload protection failed"))
  }
  let unprotected = quic_join_bytes([aad, ciphertext])
  let pn_offset = aad.length() - packet_number_length
  if unprotected.length() < pn_offset + 20 {
    return Err(
      InvalidPacket("packet is too short for header protection sample"),
    )
  }
  let sample = unprotected[pn_offset + 4:pn_offset + 20].to_owned()
  let mask = match keys.header_protection_mask(sample) {
    Ok(value) => value
    Err(_) => return Err(InvalidPacket("header protection failed"))
  }
  let protected_first = if long_header {
    normalized_first ^ (mask[0] & 0x0f)
  } else {
    normalized_first ^ (mask[0] & 0x1f)
  }
  let wire = quic_copy_with_byte(unprotected, 0, protected_first)
  let output = wire.to_array()
  for index in 0..<packet_number_length {
    output[pn_offset + index] = (output[pn_offset + index].to_int() ^
    mask[index + 1].to_int()).to_byte()
  }
  Ok(Bytes::from_array(output))
}

///|
/// Removes header protection, reconstructs the full packet number, and opens
/// an authenticated QUIC packet. The caller supplies the packet-number offset
/// because short headers carry no destination-CID length on the wire.
pub fn quic_open_packet_with_keys(
  keys : @tls.QuicPacketKeys,
  packet : Bytes,
  packet_number_offset : Int,
  largest_received : Int64,
  long_header : Bool,
) -> Result[QuicOpenedPacket, QuicError] {
  if packet_number_offset < 1 || packet.length() < packet_number_offset + 20 {
    return Err(
      InvalidPacket("packet is too short for header protection sample"),
    )
  }
  if long_header {
    let (layout_offset, payload_length) = match
      quic_long_header_packet_layout(packet) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if layout_offset != packet_number_offset {
      return Err(InvalidPacket("packet-number offset does not match header"))
    }
    if payload_length > @int.MAX_VALUE.to_int64() ||
      packet_number_offset > packet.length() - payload_length.to_int() ||
      packet_number_offset + payload_length.to_int() != packet.length() {
      return Err(InvalidPacket("QUIC payload length does not match datagram"))
    }
  }
  let sample = packet[packet_number_offset + 4:packet_number_offset + 20].to_owned()
  let mask = match keys.header_protection_mask(sample) {
    Ok(value) => value
    Err(_) => return Err(InvalidPacket("header protection failed"))
  }
  let protected_first = packet[0].to_int()
  let first = if long_header {
    protected_first ^ (mask[0].to_int() & 0x0f)
  } else {
    protected_first ^ (mask[0].to_int() & 0x1f)
  }
  if (first & 0x40) == 0 ||
    (long_header && (first & 0x80) == 0) ||
    (!long_header && (first & 0x80) != 0) {
    return Err(InvalidPacket("invalid protected packet header"))
  }
  let packet_number_length = (first & 0x03) + 1
  if packet.length() < packet_number_offset + packet_number_length + 16 {
    return Err(InvalidPacket("packet ciphertext is truncated"))
  }
  let unprotected = packet.to_array()
  unprotected[0] = first.to_byte()
  for index in 0..<packet_number_length {
    unprotected[packet_number_offset + index] = (packet[packet_number_offset +
    index].to_int() ^
    mask[index + 1].to_int()).to_byte()
  }
  if (long_header && (first & 0x0c) != 0) ||
    (!long_header && (first & 0x18) != 0) {
    return Err(InvalidPacket("QUIC reserved bits are non-zero"))
  }
  let mut truncated = 0L
  for index in 0..<packet_number_length {
    truncated = (truncated << 8) |
      unprotected[packet_number_offset + index].to_int().to_int64()
  }
  let full_packet_number = match
    quic_reconstruct_packet_number(
      truncated, packet_number_length, largest_received,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let header_end = packet_number_offset + packet_number_length
  let header = Bytes::from_array(unprotected[:header_end])
  let ciphertext = packet[header_end:].to_owned()
  let payload = match keys.open(full_packet_number, header, ciphertext) {
    Ok(value) => value
    Err(_) => return Err(InvalidPacket("packet authentication failed"))
  }
  Ok({
    header,
    payload,
    packet_number: full_packet_number,
    packet_number_length,
    key_phase: !long_header && (first & 0x04) != 0,
  })
}

///|
/// Compatibility entry point retained for callers that used the old stub.
/// Packet protection necessarily needs negotiated keys; callers must use
/// `quic_protect_packet_with_keys` once TLS has produced them.
pub fn quic_protect_packet(_packet : Bytes) -> Result[Bytes, QuicError] {
  Err(Unsupported("packet keys are required for QUIC protection"))
}
