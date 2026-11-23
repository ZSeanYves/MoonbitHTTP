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
  quic_join_bytes([
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
    quic_join_bytes([
      b"\xc0",
      quic_builder_u32(QUIC_VERSION_NEGOTIATION),
      quic_builder_cid(destination),
      quic_builder_cid(source),
      quic_join_bytes(versions),
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
  let without_tag = quic_join_bytes([
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
  Ok(quic_join_bytes([without_tag, tag]))
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
    // Header protection samples 16 bytes starting four bytes after the PN offset.
    let length = unpadded_length
      .max(20L)
      .max(lower)
      .max(minimum.to_int64() - fixed)
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
  if options.token.length() > QUIC_MAX_PACKET_SIZE {
    return Err(InvalidPacket("Initial token is too large"))
  }
  quic_long_layout(0, options, payload).bind(layout => layout.seal(keys))
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
  quic_long_layout(
    packet_type,
    {
      version,
      destination,
      source,
      token,
      packet_number,
      packet_number_length,
      min_datagram_size,
      max_datagram_size,
    },
    payload,
  ).bind(layout => layout.seal(keys))
}

///|
priv struct QuicPacketLayout {
  prefix : Bytes
  number : Int64
  number_length : Int
  payload : Bytes
  padding : Int
  long_header : Bool
}

///|
fn QuicPacketLayout::wire_size(self : QuicPacketLayout) -> Int {
  self.prefix.length() +
  self.number_length +
  self.payload.length() +
  self.padding +
  16
}

///|
fn quic_long_layout(
  packet_type : Int,
  options : QuicInitialPacketOptions,
  payload : Bytes,
) -> Result[QuicPacketLayout, QuicError] {
  guard packet_type >= 0 && packet_type <= 2 && options.version >= 0 else {
    return Err(InvalidPacket("invalid long header type or version"))
  }
  if packet_type != 0 && !options.token.is_empty() {
    return Err(InvalidPacket("only Initial packets carry a token"))
  }
  if options.min_datagram_size < 0 ||
    options.max_datagram_size < options.min_datagram_size {
    return Err(InvalidPacket("invalid datagram bounds"))
  }
  if options.packet_number_length < 1 || options.packet_number_length > 4 {
    return Err(InvalidPacket("invalid packet number length"))
  }
  // A nonempty token is entirely inside the datagram. Reject it before
  // allocating the header if it cannot fit.
  if options.token.length() > options.max_datagram_size {
    return Err(InvalidPacket("token exceeds datagram limit"))
  }
  let prefix = Buffer()
  prefix.write_byte((0xc0 | (packet_type << 4)).to_byte())
  prefix.write_int_be(options.version)
  prefix.write_bytes(quic_builder_cid(options.destination))
  prefix.write_bytes(quic_builder_cid(options.source))
  if packet_type == 0 {
    prefix.write_bytes(
      QuicVarInt::{ value: options.token.length().to_int64(), }.encode(),
    )
    prefix.write_bytes(options.token)
  }
  let padding = match
    quic_builder_padding(
      prefix.length(),
      payload.length(),
      options.packet_number_length,
      options.min_datagram_size,
      options.max_datagram_size,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let length = options.packet_number_length + payload.length() + padding + 16
  prefix.write_bytes(QuicVarInt::{ value: length.to_int64(), }.encode())
  Ok({
    prefix: prefix.to_bytes(),
    number: options.packet_number,
    number_length: options.packet_number_length,
    payload,
    padding,
    long_header: true,
  })
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
  quic_short_layout(
    destination,
    packet_number,
    packet_number_length,
    payload,
    0,
    @int.MAX_VALUE,
  ).bind(layout => layout.seal(keys, key_phase~))
}

///|
fn quic_short_layout(
  destination : ConnectionId,
  packet_number : Int64,
  packet_number_length : Int,
  payload : Bytes,
  minimum : Int,
  maximum : Int,
) -> Result[QuicPacketLayout, QuicError] {
  if packet_number_length < 1 || packet_number_length > 4 {
    return Err(InvalidPacket("invalid short-header packet number length"))
  }
  let header_size = 1 + destination.bytes().length() + packet_number_length
  let overhead = header_size + 16
  let padding = (4 - packet_number_length - payload.length())
    .max((minimum - overhead).max(0) - payload.length())
    .max(0)
  if overhead.to_int64() + payload.length().to_int64() + padding.to_int64() >
    maximum.to_int64() {
    return Err(LimitExceeded("QUIC datagram", maximum))
  }
  let prefix = quic_join_bytes([b"\x40", destination.bytes()])
  Ok({
    prefix,
    number: packet_number,
    number_length: packet_number_length,
    payload,
    padding,
    long_header: false,
  })
}

///|
fn QuicPacketLayout::seal(
  self : QuicPacketLayout,
  keys : @tls.QuicPacketKeys,
  key_phase? : Bool = false,
  feedback_at? : Int? = None,
) -> Result[Bytes, QuicError] {
  let prefix = if key_phase && !self.long_header {
    quic_copy_with_byte(self.prefix, 0, b'\x44')
  } else {
    self.prefix
  }
  let plaintext = if self.padding == 0 && feedback_at is None {
    self.payload
  } else {
    let padded = FixedArray::make(self.payload.length() + self.padding, b'\x00')
    padded.blit_from_bytes(0, self.payload, 0, self.payload.length())
    if feedback_at is Some(index) {
      padded[index] = b'\x01'
    }
    padded.unsafe_reinterpret_as_bytes()
  }
  quic_protect_packet_with_keys(
    keys,
    prefix,
    self.number,
    self.number_length,
    plaintext,
    self.long_header,
  )
}
