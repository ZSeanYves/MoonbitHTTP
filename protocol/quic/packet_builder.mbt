///|
/// Options for constructing a QUIC v1 Initial packet. Packet padding is
/// calculated by the builder so the resulting datagram meets the minimum
/// client Initial size without changing the caller's application payload.
pub(all) struct QuicInitialPacketOptions {
  version : Int
  destination : ConnectionId
  source : ConnectionId
  token : Bytes
  packet_number : Int64
  packet_number_length : Int
  min_datagram_size : Int
  max_datagram_size : Int
} derive(Eq, Debug)

///|
pub fn QuicInitialPacketOptions::defaults(
  destination : ConnectionId,
  source : ConnectionId,
  packet_number : Int64,
) -> QuicInitialPacketOptions {
  {
    version: QUIC_VERSION_1,
    destination,
    source,
    token: b"",
    packet_number,
    packet_number_length: 2,
    min_datagram_size: 1200,
    max_datagram_size: QUIC_MAX_PACKET_SIZE,
  }
}

///|
fn quic_builder_join(parts : Array[Bytes]) -> Bytes {
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
fn quic_builder_u32(value : Int) -> Bytes {
  Bytes::from_array([
    (value >> 24).to_byte(),
    (value >> 16).to_byte(),
    (value >> 8).to_byte(),
    value.to_byte(),
  ])
}

///|
fn quic_builder_cid(cid : ConnectionId) -> Bytes {
  quic_builder_join([
    Bytes::from_array([cid.bytes().length().to_byte()]),
    cid.bytes(),
  ])
}

///|
/// Builds an unauthenticated Version Negotiation packet. CID echo checks
/// reject unrelated responses but do not authenticate the peer. Only QUIC v1
/// is implemented; a valid no-common-version response stops the connection.
pub fn quic_build_version_negotiation_packet(
  destination : ConnectionId,
  source : ConnectionId,
  supported_versions : Array[Int],
) -> Result[Bytes, QuicError] {
  if supported_versions.is_empty() ||
    destination.bytes().length() > QUIC_MAX_CONNECTION_ID ||
    source.bytes().length() > QUIC_MAX_CONNECTION_ID {
    return Err(InvalidPacket("invalid Version Negotiation packet"))
  }
  let versions : Array[Bytes] = []
  for version in supported_versions {
    if version == 0 {
      return Err(InvalidPacket("invalid QUIC version"))
    }
    versions.push(quic_builder_u32(version))
  }
  Ok(
    quic_builder_join([
      b"\xc0",
      quic_builder_u32(QUIC_VERSION_NEGOTIATION),
      quic_builder_cid(destination),
      quic_builder_cid(source),
      quic_builder_join(versions),
    ]),
  )
}

///|
/// Builds a Retry packet and its RFC 9001 integrity tag.  `original_destination`
/// is the client's first Initial DCID, while `destination` is the client's
/// Source CID and `source` is the server's fresh Retry CID.
pub fn quic_build_retry_packet(
  version : Int,
  destination : ConnectionId,
  source : ConnectionId,
  token : Bytes,
  original_destination : ConnectionId,
) -> Result[Bytes, QuicError] {
  if version != QUIC_VERSION_1 ||
    destination.bytes().length() > QUIC_MAX_CONNECTION_ID ||
    source.bytes().length() > QUIC_MAX_CONNECTION_ID ||
    token.is_empty() {
    return Err(InvalidPacket("invalid Retry packet arguments"))
  }
  let without_tag = quic_builder_join([
    b"\xf0",
    quic_builder_u32(version),
    quic_builder_cid(destination),
    quic_builder_cid(source),
    token,
  ])
  let tag = match
    @tls.quic_retry_integrity_tag(original_destination.bytes(), without_tag) {
    Ok(value) => value
    Err(_) => return Err(InvalidPacket("Retry integrity protection failed"))
  }
  Ok(quic_builder_join([without_tag, tag]))
}

///|
/// Select the smallest representable padded packet within the requested
/// interval. Length-varint width changes leave gaps in possible total sizes;
/// enumerating the four widths terminates even when the minimum is in a gap.
fn quic_builder_padding(
  prefix_length : Int,
  payload_length : Int,
  packet_number_length : Int,
  minimum : Int,
  maximum : Int,
) -> Result[Int, QuicError] {
  let unpadded_length = payload_length.to_int64() +
    packet_number_length.to_int64() +
    16L
  for
    (width, lower, upper) in [
      (1, 0L, 63L),
      (2, 64L, 16383L),
      (4, 16384L, 1073741823L),
      (8, 1073741824L, QUIC_MAX_VARINT),
    ] {
    let fixed = prefix_length.to_int64() + width.to_int64()
    let length = unpadded_length.max(lower).max(minimum.to_int64() - fixed)
    if length <= upper && fixed + length <= maximum.to_int64() {
      return Ok((length - unpadded_length).to_int())
    }
  }
  Err(InvalidPacket("packet exceeds datagram limit"))
}

///|
/// Builds and protects a QUIC v1 Initial packet. The packet length field is
/// derived from the encrypted payload and is therefore consistent with the
/// wire representation. The caller supplies the direction-specific Initial
/// key; no TLS record framing is used.
pub fn quic_build_initial_packet(
  keys : @tls.QuicPacketKeys,
  options : QuicInitialPacketOptions,
  payload : Bytes,
) -> Result[Bytes, QuicError] {
  if options.version != QUIC_VERSION_1 {
    return Err(InvalidPacket("only QUIC version 1 is supported"))
  }
  if options.min_datagram_size < 0 ||
    options.max_datagram_size < options.min_datagram_size {
    return Err(InvalidPacket("invalid Initial datagram bounds"))
  }
  if options.destination.bytes().length() > QUIC_MAX_CONNECTION_ID ||
    options.source.bytes().length() > QUIC_MAX_CONNECTION_ID {
    return Err(InvalidPacket("connection ID exceeds 20 bytes"))
  }
  if options.token.length() > QUIC_MAX_PACKET_SIZE {
    return Err(InvalidPacket("Initial token is too large"))
  }
  if options.packet_number < 0L ||
    options.packet_number > QUIC_MAX_VARINT ||
    options.packet_number_length < 1 ||
    options.packet_number_length > 4 {
    return Err(InvalidPacket("invalid Initial packet number"))
  }
  let pn_limit = match options.packet_number_length {
    1 => 0xffL
    2 => 0xffffL
    3 => 0xffffffL
    _ => 0xffffffffL
  }
  if options.packet_number > pn_limit {
    return Err(InvalidPacket("packet number does not fit its wire length"))
  }
  let token_length = match QuicVarInt::new(options.token.length().to_int64()) {
    Ok(value) => value
    Err(_) => return Err(InvalidPacket("Initial token length overflows"))
  }
  let base_prefix = quic_builder_join([
    Bytes::from_array([0xc0]),
    quic_builder_u32(options.version),
    quic_builder_cid(options.destination),
    quic_builder_cid(options.source),
    token_length.encode(),
    options.token,
  ])
  let padding = match
    quic_builder_padding(
      base_prefix.length(),
      payload.length(),
      options.packet_number_length,
      options.min_datagram_size,
      options.max_datagram_size,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let ciphertext_length = payload.length() + padding + 16
  let length_varint = match
    QuicVarInt::new(
      (options.packet_number_length + ciphertext_length).to_int64(),
    ) {
    Ok(value) => value
    Err(_) => return Err(InvalidPacket("Initial payload length overflows"))
  }
  let header_prefix = quic_builder_join([base_prefix, length_varint.encode()])
  let padded_payload = if padding == 0 {
    payload
  } else {
    quic_builder_join([
      payload,
      Bytes::from_array(FixedArray::make(padding, b'\x00')),
    ])
  }
  quic_protect_packet_with_keys(
    keys,
    header_prefix,
    options.packet_number,
    options.packet_number_length,
    padded_payload,
    true,
  )
}

///|
/// Builds a protected QUIC long-header packet for packet types 0 (Initial),
/// 1 (0-RTT), or 2 (Handshake).  `keys` must be the directional keys for the
/// selected packet number space.  The function is intentionally generic so a
/// driver can use the same framing rules while TLS keys change.
pub fn quic_build_long_packet(
  keys : @tls.QuicPacketKeys,
  packet_type : Int,
  version : Int,
  destination : ConnectionId,
  source : ConnectionId,
  token : Bytes,
  packet_number : Int64,
  packet_number_length : Int,
  payload : Bytes,
  min_datagram_size? : Int = 0,
  max_datagram_size? : Int = QUIC_MAX_PACKET_SIZE,
) -> Result[Bytes, QuicError] {
  if packet_type < 0 || packet_type > 2 {
    return Err(InvalidPacket("invalid QUIC long-header packet type"))
  }
  if version < 0 {
    return Err(InvalidPacket("invalid QUIC version"))
  }
  if destination.bytes().length() > QUIC_MAX_CONNECTION_ID ||
    source.bytes().length() > QUIC_MAX_CONNECTION_ID {
    return Err(LimitExceeded("connection ID", QUIC_MAX_CONNECTION_ID))
  }
  if packet_type != 0 && !token.is_empty() {
    return Err(InvalidPacket("only Initial packets carry a token"))
  }
  if min_datagram_size < 0 || max_datagram_size < min_datagram_size {
    return Err(InvalidPacket("invalid datagram bounds"))
  }
  if packet_number < 0L ||
    packet_number > QUIC_MAX_VARINT ||
    packet_number_length < 1 ||
    packet_number_length > 4 {
    return Err(InvalidPacket("invalid packet number"))
  }
  let pn_limit = match packet_number_length {
    1 => 0xffL
    2 => 0xffffL
    3 => 0xffffffL
    _ => 0xffffffffL
  }
  if packet_number > pn_limit {
    return Err(InvalidPacket("packet number does not fit its wire length"))
  }
  let token_length = match QuicVarInt::new(token.length().to_int64()) {
    Ok(value) => value
    Err(_) => return Err(InvalidPacket("token length overflows"))
  }
  let first = match packet_type {
    0 => 0xc0
    1 => 0xd0
    _ => 0xe0
  }
  let prefix = quic_builder_join([
    Bytes::from_array([first.to_byte()]),
    quic_builder_u32(version),
    quic_builder_cid(destination),
    quic_builder_cid(source),
    if packet_type == 0 {
      token_length.encode()
    } else {
      b""
    },
    if packet_type == 0 {
      token
    } else {
      b""
    },
  ])
  let padding = match
    quic_builder_padding(
      prefix.length(),
      payload.length(),
      packet_number_length,
      min_datagram_size,
      max_datagram_size,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let ciphertext_length = payload.length() + padding + 16
  let length_varint = match
    QuicVarInt::new((packet_number_length + ciphertext_length).to_int64()) {
    Ok(value) => value
    Err(_) => return Err(InvalidPacket("payload length overflows"))
  }
  let header_prefix = quic_builder_join([prefix, length_varint.encode()])
  let padded_payload = if padding == 0 {
    payload
  } else {
    quic_builder_join([
      payload,
      Bytes::from_array(FixedArray::make(padding, b'\x00')),
    ])
  }
  quic_protect_packet_with_keys(
    keys, header_prefix, packet_number, packet_number_length, padded_payload, true,
  )
}

///|
/// Builds a protected QUIC short-header packet.  The destination connection
/// ID length is carried by the connection context rather than the wire.
pub fn quic_build_short_packet(
  keys : @tls.QuicPacketKeys,
  destination : ConnectionId,
  packet_number : Int64,
  packet_number_length : Int,
  payload : Bytes,
  key_phase? : Bool = false,
) -> Result[Bytes, QuicError] {
  if destination.bytes().length() > QUIC_MAX_CONNECTION_ID {
    return Err(LimitExceeded("connection ID", QUIC_MAX_CONNECTION_ID))
  }
  if packet_number_length < 1 || packet_number_length > 4 {
    return Err(InvalidPacket("invalid short-header packet number length"))
  }
  let padding_length = (4 - packet_number_length - payload.length()).max(0)
  let payload = if padding_length > 0 {
    let padding = FixedArray::make(padding_length, b'\x00')
    quic_builder_join([payload, padding.unsafe_reinterpret_as_bytes()])
  } else {
    payload
  }
  let key_bit = if key_phase { 0x04 } else { 0 }
  let prefix = quic_builder_join([
    Bytes::from_array([(0x40 | key_bit).to_byte()]),
    destination.bytes(),
  ])
  quic_protect_packet_with_keys(
    keys, prefix, packet_number, packet_number_length, payload, false,
  )
}
