///|
pub struct ConnectionId {
  bytes : Bytes
} derive(Eq, Debug)

///|
pub fn ConnectionId::new(bytes : Bytes) -> Result[ConnectionId, QuicError] {
  if bytes.length() > QUIC_MAX_CONNECTION_ID {
    return Err(LimitExceeded("connection id", QUIC_MAX_CONNECTION_ID))
  }
  Ok({ bytes, })
}

///|
pub fn ConnectionId::bytes(self : ConnectionId) -> Bytes {
  self.bytes
}

///|
pub(all) enum PacketNumberSpace {
  Initial
  Handshake
  Application
} derive(Eq, Debug)

///|
pub(all) enum QuicRole {
  Client
  Server
} derive(Eq, Debug)

///|
pub(all) struct InitialPacket {
  version : Int
  destination : ConnectionId
  source : ConnectionId
  token : Bytes
  payload_length : Int64
  packet_number : Int64
  packet_number_length : Int
} derive(Eq, Debug)

///|
pub(all) struct ZeroRttPacket {
  version : Int
  destination : ConnectionId
  source : ConnectionId
  payload_length : Int64
  packet_number : Int64
  packet_number_length : Int
} derive(Eq, Debug)

///|
pub(all) struct HandshakePacket {
  version : Int
  destination : ConnectionId
  source : ConnectionId
  payload_length : Int64
  packet_number : Int64
  packet_number_length : Int
} derive(Eq, Debug)

///|
pub(all) struct RetryPacket {
  version : Int
  destination : ConnectionId
  source : ConnectionId
  token : Bytes
  integrity_tag : Bytes
} derive(Eq, Debug)

///|
/// A Version Negotiation packet is not packet-protected and carries the
/// versions supported by the sender.  Its destination/source IDs are retained
/// so a client can reject unsolicited negotiation responses.
pub(all) struct VersionNegotiationPacket {
  destination : ConnectionId
  source : ConnectionId
  versions : Array[Int]
} derive(Eq, Debug)

///|
pub(all) struct ShortPacket {
  destination : ConnectionId
  packet_number : Int64
  packet_number_length : Int
  key_phase : Bool
} derive(Eq, Debug)

///|
pub(all) enum QuicPacketHeader {
  Initial(InitialPacket)
  ZeroRtt(ZeroRttPacket)
  Handshake(HandshakePacket)
  Retry(RetryPacket)
  VersionNegotiation(VersionNegotiationPacket)
  Short(ShortPacket)
} derive(Eq, Debug)

///|
fn take_connection_id(
  input : BytesView,
  offset : Int,
) -> Result[(ConnectionId, Int), QuicError] {
  if offset < 0 || offset >= input.length() {
    return Err(NeedMoreInput)
  }
  let length = input[offset].to_int()
  if length > QUIC_MAX_CONNECTION_ID {
    return Err(InvalidPacket("connection id exceeds 20 bytes"))
  }
  if input.length() - offset - 1 < length {
    return Err(NeedMoreInput)
  }
  let id = match
    ConnectionId::new(input[offset + 1:offset + 1 + length].to_owned()) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok((id, offset + 1 + length))
}

///|
fn decode_truncated_packet_number(
  input : BytesView,
  offset : Int,
  length : Int,
) -> Result[(Int64, Int), QuicError] {
  if length < 1 ||
    length > 4 ||
    offset < 0 ||
    offset > input.length() ||
    input.length() - offset < length {
    return Err(NeedMoreInput)
  }
  let mut value : Int64 = 0L
  for index in 0..<length {
    value = (value << 8) | input[offset + index].to_int().to_int64()
  }
  Ok((value, offset + length))
}

///|
fn packet_version(input : BytesView) -> Int {
  (input[1].to_int() << 24) |
  (input[2].to_int() << 16) |
  (input[3].to_int() << 8) |
  input[4].to_int()
}

///|
/// Parses a QUIC packet header. Short headers require the destination CID
/// length from the connection context because it is not encoded on the wire.
pub fn quic_decode_packet_header(
  input : BytesView,
  short_destination_length? : Int = 0,
  canonical_varints? : Bool = false,
) -> Result[(QuicPacketHeader, Int), QuicError] {
  if input.is_empty() {
    return Err(NeedMoreInput)
  }
  let first = input[0].to_int()
  let version_negotiation = (first & 0x80) != 0 &&
    input.length() >= 5 &&
    packet_version(input) == 0
  if (first & 0x40) == 0 && !version_negotiation {
    return Err(InvalidPacket("fixed bit is not set"))
  }
  if (first & 0x80) == 0 {
    let cid_len = short_destination_length
    if cid_len < 0 ||
      cid_len > QUIC_MAX_CONNECTION_ID ||
      input.length() < 1 + cid_len {
      return Err(NeedMoreInput)
    }
    let destination = match ConnectionId::new(input[1:1 + cid_len].to_owned()) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let pn_length = (first & 0x03) + 1
    let (packet_number, end) = match
      decode_truncated_packet_number(input, 1 + cid_len, pn_length) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    return Ok(
      (
        Short({
          destination,
          packet_number,
          packet_number_length: pn_length,
          key_phase: (first & 0x04) != 0,
        }),
        end,
      ),
    )
  }
  if input.length() < 5 {
    return Err(NeedMoreInput)
  }
  let version = packet_version(input)
  let (destination, after_destination) = match take_connection_id(input, 5) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (source, offset0) = match take_connection_id(input, after_destination) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut offset = offset0
  if version == QUIC_VERSION_NEGOTIATION {
    let remaining = input.length() - offset
    if remaining < 4 || remaining % 4 != 0 {
      return Err(InvalidPacket("Version Negotiation list is malformed"))
    }
    let versions : Array[Int] = []
    let version_count = remaining / 4
    for index in 0..<version_count {
      let at = offset + index * 4
      versions.push(
        (input[at].to_int() << 24) |
        (input[at + 1].to_int() << 16) |
        (input[at + 2].to_int() << 8) |
        input[at + 3].to_int(),
      )
    }
    return Ok(
      (VersionNegotiation({ destination, source, versions, }), input.length()),
    )
  }
  let packet_type = (first >> 4) & 0x03
  if packet_type == 3 {
    if input.length() - offset < 16 {
      return Err(NeedMoreInput)
    }
    let token_end = input.length() - 16
    if token_end < offset {
      return Err(InvalidPacket("invalid Retry token"))
    }
    return Ok(
      (
        Retry({
          version,
          destination,
          source,
          token: input[offset:token_end].to_owned(),
          integrity_tag: input[token_end:].to_owned(),
        }),
        input.length(),
      ),
    )
  }
  let token = if packet_type == 0 {
    let (token_length, used) = match
      quic_decode_varint(input[offset:], canonical=canonical_varints) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    offset += used
    let token_length = match varint_to_index(token_length.value()) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if token_length > input.length() - offset {
      return Err(NeedMoreInput)
    }
    let result = input[offset:offset + token_length].to_owned()
    offset += token_length
    result
  } else {
    b""
  }
  let (payload_length, used) = match
    quic_decode_varint(input[offset:], canonical=canonical_varints) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  offset += used
  let payload_length = payload_length.value()
  if payload_length < 1L {
    return Err(InvalidPacket("payload length does not include packet number"))
  }
  let pn_length = (first & 0x03) + 1
  let (packet_number, end) = match
    decode_truncated_packet_number(input, offset, pn_length) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let header : QuicPacketHeader = match packet_type {
    0 =>
      Initial({
        version,
        destination,
        source,
        token,
        payload_length,
        packet_number,
        packet_number_length: pn_length,
      })
    1 =>
      ZeroRtt({
        version,
        destination,
        source,
        payload_length,
        packet_number,
        packet_number_length: pn_length,
      })
    _ =>
      Handshake({
        version,
        destination,
        source,
        payload_length,
        packet_number,
        packet_number_length: pn_length,
      })
  }
  Ok((header, end))
}
