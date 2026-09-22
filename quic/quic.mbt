///|
pub const QUIC_VERSION_1 : Int = 1

///|
pub const QUIC_MAX_CONNECTION_ID : Int = 20

///|
pub const QUIC_MAX_PACKET_SIZE : Int = 65527

///|
pub const QUIC_MAX_VARINT : Int64 = 0x3fffffffffffffffL

///|
pub(all) suberror QuicError {
  NeedMoreInput
  UnexpectedEof(String)
  Malformed(String)
  NonCanonicalVarInt
  VarIntOverflow
  LimitExceeded(String, Int)
  InvalidPacket(String)
  InvalidFrame(String)
  InvalidTransportParameter(String)
  Protocol(Int64, String)
  FlowControl(Int64, String)
  StreamClosed(Int64)
  ConnectionClosed(Int64, String)
  Policy(@transport.PolicyError)
  Transport(@transport.TransportError)
  Unsupported(String)
} derive(Eq, Debug)

///|
pub(all) struct QuicLimits {
  max_packet_size : Int
  max_datagram_size : Int
  max_frame_payload : Int
  max_ack_ranges : Int
  max_crypto_bytes : Int
  max_streams : Int
  max_connection_data : Int64
  max_stream_data : Int64
} derive(Eq, Debug)

///|
pub fn QuicLimits::defaults() -> QuicLimits {
  {
    max_packet_size: 1350,
    max_datagram_size: 65527,
    max_frame_payload: 16 * 1024 * 1024,
    max_ack_ranges: 256,
    max_crypto_bytes: 1024 * 1024,
    max_streams: 100,
    max_connection_data: 16 * 1024 * 1024L,
    max_stream_data: 1024 * 1024L,
  }
}

///|
pub fn QuicLimits::validate(self : QuicLimits) -> Result[Unit, QuicError] {
  let values : Array[(String, Int, Bool)] = [
    ("max_packet_size", self.max_packet_size, false),
    ("max_datagram_size", self.max_datagram_size, false),
    ("max_frame_payload", self.max_frame_payload, true),
    ("max_ack_ranges", self.max_ack_ranges, false),
    ("max_crypto_bytes", self.max_crypto_bytes, true),
    ("max_streams", self.max_streams, false),
  ]
  for entry in values {
    let (name, value, zero_ok) = entry
    if value < 0 || (!zero_ok && value == 0) {
      return Err(LimitExceeded(name, value))
    }
  }
  if self.max_connection_data < 0L || self.max_connection_data > QUIC_MAX_VARINT {
    return Err(LimitExceeded("max_connection_data", @int.MAX_VALUE))
  }
  if self.max_stream_data < 0L || self.max_stream_data > QUIC_MAX_VARINT {
    return Err(LimitExceeded("max_stream_data", @int.MAX_VALUE))
  }
  if self.max_stream_data > @int.MAX_VALUE.to_int64() {
    return Err(LimitExceeded("max_stream_data", @int.MAX_VALUE))
  }
  if self.max_packet_size > self.max_datagram_size {
    return Err(LimitExceeded("max_packet_size", self.max_packet_size))
  }
  Ok(())
}

///|
pub(all) struct QuicVarInt {
  value : Int64
} derive(Eq, Debug, Compare)

///|
pub fn QuicVarInt::new(value : Int64) -> Result[QuicVarInt, QuicError] {
  if value < 0L || value > QUIC_MAX_VARINT {
    return Err(VarIntOverflow)
  }
  Ok({ value, })
}

///|
pub fn QuicVarInt::value(self : QuicVarInt) -> Int64 {
  self.value
}

///|
pub fn QuicVarInt::encoded_length(self : QuicVarInt) -> Int {
  if self.value <= 63L {
    1
  } else if self.value <= 16383L {
    2
  } else if self.value <= 1073741823L {
    4
  } else {
    8
  }
}

///|
pub fn QuicVarInt::encode(self : QuicVarInt) -> Bytes {
  match self.encoded_length() {
    1 => Bytes::from_array([self.value.to_byte()])
    2 =>
      Bytes::from_array([
        ((self.value >> 8) | 0x40L).to_byte(),
        self.value.to_byte(),
      ])
    4 =>
      Bytes::from_array([
        ((self.value >> 24) | 0x80L).to_byte(),
        (self.value >> 16).to_byte(),
        (self.value >> 8).to_byte(),
        self.value.to_byte(),
      ])
    _ =>
      Bytes::from_array([
        ((self.value >> 56) | 0xc0L).to_byte(),
        (self.value >> 48).to_byte(),
        (self.value >> 40).to_byte(),
        (self.value >> 32).to_byte(),
        (self.value >> 24).to_byte(),
        (self.value >> 16).to_byte(),
        (self.value >> 8).to_byte(),
        self.value.to_byte(),
      ])
  }
}

///|
fn quic_varint_length(first : Byte) -> Int {
  match first.to_int() >> 6 {
    0 => 1
    1 => 2
    2 => 4
    _ => 8
  }
}

///|
pub fn quic_decode_varint(
  input : BytesView,
  canonical? : Bool = false,
) -> Result[(QuicVarInt, Int), QuicError] {
  if input.is_empty() {
    return Err(NeedMoreInput)
  }
  let length = quic_varint_length(input[0])
  if input.length() < length {
    return Err(NeedMoreInput)
  }
  let mut value : Int64 = (input[0].to_int() & 0x3f).to_int64()
  for index in 1..<length {
    value = (value << 8) | input[index].to_int().to_int64()
  }
  let result = match QuicVarInt::new(value) {
    Ok(result) => result
    Err(error) => return Err(error)
  }
  if canonical && result.encoded_length() != length {
    return Err(NonCanonicalVarInt)
  }
  Ok((result, length))
}

///|
pub(all) struct ConnectionId {
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
  if (first & 0x40) == 0 {
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

///|
pub(all) struct AckRange {
  largest : Int64
  smallest : Int64
} derive(Eq, Debug)

///|
pub fn AckRange::new(
  largest : Int64,
  smallest : Int64,
) -> Result[AckRange, QuicError] {
  if smallest < 0L || largest < smallest || largest > QUIC_MAX_VARINT {
    return Err(InvalidFrame("ACK range bounds are invalid"))
  }
  Ok({ largest, smallest, })
}

///|
pub fn AckRange::largest(self : AckRange) -> Int64 {
  self.largest
}

///|
pub fn AckRange::smallest(self : AckRange) -> Int64 {
  self.smallest
}

///|
pub(all) struct AckFrame {
  largest_acknowledged : Int64
  ack_delay : Int64
  ranges : Array[AckRange]
  ecn_counts : (Int64, Int64, Int64)?
} derive(Eq, Debug)

///|
pub fn AckFrame::new(
  largest_acknowledged : Int64,
  ack_delay : Int64,
  ranges : Array[AckRange],
  ecn_counts? : (Int64, Int64, Int64)? = None,
) -> Result[AckFrame, QuicError] {
  if largest_acknowledged < 0L || ack_delay < 0L || ranges.is_empty() {
    return Err(InvalidFrame("ACK fields are invalid"))
  }
  if largest_acknowledged > QUIC_MAX_VARINT || ack_delay > QUIC_MAX_VARINT {
    return Err(InvalidFrame("ACK fields exceed QUIC varint range"))
  }
  if ranges[0].largest != largest_acknowledged {
    return Err(InvalidFrame("ACK largest value does not match first range"))
  }
  let mut previous_smallest = largest_acknowledged + 1L
  for range in ranges {
    if range.largest >= previous_smallest {
      return Err(InvalidFrame("ACK ranges overlap or are unordered"))
    }
    previous_smallest = range.smallest
  }
  match ecn_counts {
    Some((ect0, ect1, ce)) if ect0 < 0L || ect1 < 0L || ce < 0L =>
      return Err(InvalidFrame("negative ECN count"))
    _ => ()
  }
  Ok({ largest_acknowledged, ack_delay, ranges, ecn_counts, })
}

///|
pub fn AckFrame::ranges(self : AckFrame) -> Array[AckRange] {
  self.ranges.copy()
}

///|
pub fn AckFrame::largest_acknowledged(self : AckFrame) -> Int64 {
  self.largest_acknowledged
}

///|
pub fn AckFrame::ack_delay(self : AckFrame) -> Int64 {
  self.ack_delay
}

///|
pub(all) struct StreamFrame {
  stream_id : Int64
  offset : Int64
  data : Bytes
  fin : Bool
} derive(Eq, Debug)

///|
pub fn StreamFrame::new(
  stream_id : Int64,
  offset : Int64,
  data : Bytes,
  fin : Bool,
) -> Result[StreamFrame, QuicError] {
  if stream_id < 0L || offset < 0L {
    return Err(InvalidFrame("negative stream id or offset"))
  }
  Ok({ stream_id, offset, data, fin, })
}

///|
pub fn StreamFrame::stream_id(self : StreamFrame) -> Int64 {
  self.stream_id
}

///|
pub fn StreamFrame::offset(self : StreamFrame) -> Int64 {
  self.offset
}

///|
pub fn StreamFrame::data(self : StreamFrame) -> Bytes {
  self.data
}

///|
pub fn StreamFrame::fin(self : StreamFrame) -> Bool {
  self.fin
}

///|
pub(all) enum QuicFrame {
  Padding
  Ping
  Ack(AckFrame)
  ResetStream(Int64, Int64, Int64)
  StopSending(Int64, Int64)
  Crypto(Int64, Bytes)
  NewToken(Bytes)
  Stream(StreamFrame)
  MaxData(Int64)
  MaxStreamData(Int64, Int64)
  MaxStreams(Bool, Int64)
  DataBlocked(Int64)
  StreamDataBlocked(Int64, Int64)
  StreamsBlocked(Bool, Int64)
  NewConnectionId(Int64, Int64, ConnectionId, Bytes)
  RetireConnectionId(Int64)
  PathChallenge(Bytes)
  PathResponse(Bytes)
  ConnectionClose(Bool, Int64, Int64, Bytes)
  HandshakeDone
  Datagram(Bytes)
} derive(Eq, Debug)

///|
fn decode_frame_varint(
  payload : BytesView,
  offset : Int,
  canonical? : Bool = false,
) -> Result[(Int64, Int), QuicError] {
  if offset < 0 || offset > payload.length() {
    return Err(NeedMoreInput)
  }
  let (value, used) = match quic_decode_varint(payload[offset:], canonical~) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok((value.value(), offset + used))
}

///|
fn varint_to_index(value : Int64) -> Result[Int, QuicError] {
  if value < 0L || value > @int.MAX_VALUE.to_int64() {
    return Err(VarIntOverflow)
  }
  Ok(value.to_int())
}

///|
fn take_frame_bytes(
  payload : BytesView,
  offset : Int,
  length : Int,
) -> Result[(Bytes, Int), QuicError] {
  if length < 0 ||
    offset < 0 ||
    offset > payload.length() ||
    length > payload.length() - offset {
    return Err(NeedMoreInput)
  }
  Ok((payload[offset:offset + length].to_owned(), offset + length))
}

///|
fn decode_ack_frame(
  payload : BytesView,
  offset : Int,
  with_ecn : Bool,
  limits : QuicLimits,
) -> Result[(AckFrame, Int), QuicError] {
  let (largest, after_largest) = match decode_frame_varint(payload, offset) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (delay, after_delay) = match decode_frame_varint(payload, after_largest) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (range_count64, after_count) = match
    decode_frame_varint(payload, after_delay) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let range_count = match varint_to_index(range_count64) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if range_count > limits.max_ack_ranges {
    return Err(LimitExceeded("ACK ranges", limits.max_ack_ranges))
  }
  let (first_range, first_cursor) = match
    decode_frame_varint(payload, after_count) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if first_range > largest {
    return Err(InvalidFrame("ACK first range underflows"))
  }
  let first = match AckRange::new(largest, largest - first_range) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let ranges = [first]
  let mut cursor = first_cursor
  let mut previous_smallest = largest - first_range
  for _ in 0..<range_count {
    let (gap, after_gap) = match decode_frame_varint(payload, cursor) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let (range_length, after_range) = match
      decode_frame_varint(payload, after_gap) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if gap + 2L > previous_smallest {
      return Err(InvalidFrame("ACK range gap underflows packet number"))
    }
    let largest_range = previous_smallest - gap - 2L
    if range_length > largest_range {
      return Err(InvalidFrame("ACK range length underflows packet number"))
    }
    let range = match
      AckRange::new(largest_range, largest_range - range_length) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    ranges.push(range)
    previous_smallest = range.smallest
    cursor = after_range
  }
  let ecn = if with_ecn {
    let (ect0, after_ect0) = match decode_frame_varint(payload, cursor) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let (ect1, after_ect1) = match decode_frame_varint(payload, after_ect0) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let (ce, after_ce) = match decode_frame_varint(payload, after_ect1) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    cursor = after_ce
    Some((ect0, ect1, ce))
  } else {
    None
  }
  let ack = match AckFrame::new(largest, delay, ranges, ecn_counts=ecn) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok((ack, cursor))
}

///|
pub fn quic_decode_frames(
  payload : BytesView,
  limits? : QuicLimits = QuicLimits::defaults(),
) -> Result[Array[QuicFrame], QuicError] {
  match limits.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if payload.length() > limits.max_frame_payload {
    return Err(LimitExceeded("frame payload", limits.max_frame_payload))
  }
  let frames : Array[QuicFrame] = []
  let mut offset = 0
  while offset < payload.length() {
    let (typ64, next) = match
      decode_frame_varint(payload, offset, canonical=true) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let typ = match varint_to_index(typ64) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    offset = next
    if typ == 0x00 {
      frames.push(Padding)
    } else if typ == 0x01 {
      frames.push(Ping)
    } else if typ == 0x02 || typ == 0x03 {
      let (ack, cursor) = match
        decode_ack_frame(payload, offset, typ == 0x03, limits) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      frames.push(Ack(ack))
      offset = cursor
    } else if typ == 0x04 {
      let (stream_id, cursor) = match decode_frame_varint(payload, offset) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let (error_code, cursor) = match decode_frame_varint(payload, cursor) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let (final_size, cursor) = match decode_frame_varint(payload, cursor) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      frames.push(ResetStream(stream_id, error_code, final_size))
      offset = cursor
    } else if typ == 0x05 {
      let (stream_id, cursor) = match decode_frame_varint(payload, offset) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let (error_code, cursor) = match decode_frame_varint(payload, cursor) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      frames.push(StopSending(stream_id, error_code))
      offset = cursor
    } else if typ == 0x06 {
      let (crypto_offset, cursor) = match decode_frame_varint(payload, offset) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let (length64, cursor) = match decode_frame_varint(payload, cursor) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let length = match varint_to_index(length64) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if length > limits.max_crypto_bytes {
        return Err(LimitExceeded("CRYPTO data", limits.max_crypto_bytes))
      }
      let (data, cursor) = match take_frame_bytes(payload, cursor, length) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      frames.push(Crypto(crypto_offset, data))
      offset = cursor
    } else if typ == 0x07 {
      let (length64, cursor) = match decode_frame_varint(payload, offset) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let length = match varint_to_index(length64) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let (token, cursor) = match take_frame_bytes(payload, cursor, length) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      frames.push(NewToken(token))
      offset = cursor
    } else if typ >= 0x08 && typ <= 0x0f {
      let (stream_id, after_stream) = match
        decode_frame_varint(payload, offset) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let has_offset = (typ & 0x04) != 0
      let has_length = (typ & 0x02) != 0
      let fin = (typ & 0x01) != 0
      let (stream_offset, after_offset) = if has_offset {
        match decode_frame_varint(payload, after_stream) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
      } else {
        (0L, after_stream)
      }
      let (length, after_length) = if has_length {
        let (length64, cursor) = match
          decode_frame_varint(payload, after_offset) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let length = match varint_to_index(length64) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        (length, cursor)
      } else {
        (payload.length() - after_offset, after_offset)
      }
      let (data, cursor) = match
        take_frame_bytes(payload, after_length, length) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let frame = match StreamFrame::new(stream_id, stream_offset, data, fin) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      frames.push(Stream(frame))
      offset = cursor
    } else if typ == 0x10 {
      let (value, cursor) = match decode_frame_varint(payload, offset) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      frames.push(MaxData(value))
      offset = cursor
    } else if typ == 0x11 {
      let (stream_id, cursor) = match decode_frame_varint(payload, offset) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let (value, cursor) = match decode_frame_varint(payload, cursor) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      frames.push(MaxStreamData(stream_id, value))
      offset = cursor
    } else if typ == 0x12 || typ == 0x13 {
      let (value, cursor) = match decode_frame_varint(payload, offset) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      frames.push(MaxStreams(typ == 0x13, value))
      offset = cursor
    } else if typ == 0x14 {
      let (value, cursor) = match decode_frame_varint(payload, offset) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      frames.push(DataBlocked(value))
      offset = cursor
    } else if typ == 0x15 {
      let (stream_id, cursor) = match decode_frame_varint(payload, offset) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let (value, cursor) = match decode_frame_varint(payload, cursor) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      frames.push(StreamDataBlocked(stream_id, value))
      offset = cursor
    } else if typ == 0x16 || typ == 0x17 {
      let (value, cursor) = match decode_frame_varint(payload, offset) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      frames.push(StreamsBlocked(typ == 0x17, value))
      offset = cursor
    } else if typ == 0x18 {
      let (sequence, cursor) = match decode_frame_varint(payload, offset) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let (retire_prior_to, cursor) = match
        decode_frame_varint(payload, cursor) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if payload.length() - cursor < 1 {
        return Err(NeedMoreInput)
      }
      let cid_length = payload[cursor].to_int()
      if cid_length > QUIC_MAX_CONNECTION_ID ||
        payload.length() - cursor - 1 < cid_length + 16 {
        return Err(NeedMoreInput)
      }
      let cid = match
        ConnectionId::new(
          payload[cursor + 1:cursor + 1 + cid_length].to_owned(),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let token_start = cursor + 1 + cid_length
      let token = payload[token_start:token_start + 16].to_owned()
      frames.push(NewConnectionId(sequence, retire_prior_to, cid, token))
      offset = token_start + 16
    } else if typ == 0x19 {
      let (sequence, cursor) = match decode_frame_varint(payload, offset) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      frames.push(RetireConnectionId(sequence))
      offset = cursor
    } else if typ == 0x1a || typ == 0x1b {
      let (data, cursor) = match take_frame_bytes(payload, offset, 8) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if typ == 0x1a {
        frames.push(PathChallenge(data))
      } else {
        frames.push(PathResponse(data))
      }
      offset = cursor
    } else if typ == 0x1c || typ == 0x1d {
      let (error_code, cursor) = match decode_frame_varint(payload, offset) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let (frame_type, cursor) = if typ == 0x1c {
        match decode_frame_varint(payload, cursor) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
      } else {
        (0L, cursor)
      }
      let (reason_length64, cursor) = match
        decode_frame_varint(payload, cursor) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let reason_length = match varint_to_index(reason_length64) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let (reason, cursor) = match
        take_frame_bytes(payload, cursor, reason_length) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      frames.push(ConnectionClose(typ == 0x1c, error_code, frame_type, reason))
      offset = cursor
    } else if typ == 0x1e {
      frames.push(HandshakeDone)
    } else if typ == 0x30 || typ == 0x31 {
      let (length, cursor) = if typ == 0x31 {
        let (length64, cursor) = match decode_frame_varint(payload, offset) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let length = match varint_to_index(length64) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        (length, cursor)
      } else {
        (payload.length() - offset, offset)
      }
      let (data, cursor) = match take_frame_bytes(payload, cursor, length) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      frames.push(Datagram(data))
      offset = cursor
    } else {
      return Err(InvalidFrame("unknown QUIC frame type"))
    }
  }
  Ok(frames)
}

///|
pub(all) struct QuicTransportParams {
  max_idle_timeout : Int64
  max_udp_payload_size : Int
  initial_max_data : Int64
  initial_max_stream_data_bidi_local : Int64
  initial_max_stream_data_bidi_remote : Int64
  initial_max_stream_data_uni : Int64
  initial_max_streams_bidi : Int64
  initial_max_streams_uni : Int64
  active_connection_id_limit : Int64
  disable_active_migration : Bool
} derive(Eq, Debug)

///|
pub fn QuicTransportParams::defaults() -> QuicTransportParams {
  {
    max_idle_timeout: 30000L,
    max_udp_payload_size: 1200,
    initial_max_data: 16 * 1024 * 1024L,
    initial_max_stream_data_bidi_local: 1024 * 1024L,
    initial_max_stream_data_bidi_remote: 1024 * 1024L,
    initial_max_stream_data_uni: 1024 * 1024L,
    initial_max_streams_bidi: 100L,
    initial_max_streams_uni: 3L,
    active_connection_id_limit: 2L,
    disable_active_migration: false,
  }
}

///|
pub fn QuicTransportParams::validate(
  self : QuicTransportParams,
) -> Result[Unit, QuicError] {
  if self.max_udp_payload_size < 1200 ||
    self.max_udp_payload_size > QUIC_MAX_PACKET_SIZE {
    return Err(InvalidTransportParameter("max_udp_payload_size"))
  }
  let values : Array[(String, Int64)] = [
    ("max_idle_timeout", self.max_idle_timeout),
    ("initial_max_data", self.initial_max_data),
    (
      "initial_max_stream_data_bidi_local",
      self.initial_max_stream_data_bidi_local,
    ),
    (
      "initial_max_stream_data_bidi_remote",
      self.initial_max_stream_data_bidi_remote,
    ),
    ("initial_max_stream_data_uni", self.initial_max_stream_data_uni),
    ("initial_max_streams_bidi", self.initial_max_streams_bidi),
    ("initial_max_streams_uni", self.initial_max_streams_uni),
  ]
  for entry in values {
    let (name, value) = entry
    if value < 0L || value > QUIC_MAX_VARINT {
      return Err(InvalidTransportParameter(name))
    }
  }
  if self.active_connection_id_limit < 2L ||
    self.active_connection_id_limit > QUIC_MAX_VARINT {
    return Err(InvalidTransportParameter("active_connection_id_limit"))
  }
  Ok(())
}

///|
pub(all) enum QuicConnectionState {
  Handshaking
  Established
  Draining
  Closed
} derive(Eq, Debug)

///|
pub(all) struct QuicStreamState {
  id : Int64
  mut send_max : Int64
  mut recv_max : Int64
  mut send_offset : Int64
  mut recv_offset : Int64
  mut fin_sent : Bool
  mut fin_received : Bool
  mut recv_final_size : Int64?
  mut recv_ranges : Array[(Int64, Int64)]
  reassembler : QuicCryptoReassembler
  mut reset : Bool
} derive(Eq, Debug)

///|
fn quic_new_stream_state(
  id : Int64,
  send_max : Int64,
  recv_max : Int64,
  reassembly_limit : Int,
) -> Result[QuicStreamState, QuicError] {
  let reassembler = match
    QuicCryptoReassembler::new(max_bytes=reassembly_limit) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    id,
    send_max,
    recv_max,
    send_offset: 0L,
    recv_offset: 0L,
    fin_sent: false,
    fin_received: false,
    recv_final_size: None,
    recv_ranges: [],
    reassembler,
    reset: false,
  })
}

///|
/// Returns the bytes in `[start, end)` that were not received before and
/// merges the new interval into the stream's received range set. QUIC allows
/// retransmitted and overlapping STREAM frames; flow control must count each
/// byte only once.
fn QuicStreamState::insert_received_range(
  self : QuicStreamState,
  start : Int64,
  end : Int64,
) -> Int64 {
  if start >= end {
    return 0L
  }
  let mut remaining : Array[(Int64, Int64)] = [(start, end)]
  for existing in self.recv_ranges {
    let (left, right) = existing
    let next : Array[(Int64, Int64)] = []
    for candidate in remaining {
      let (candidate_left, candidate_right) = candidate
      if right <= candidate_left || left >= candidate_right {
        next.push(candidate)
      } else {
        if candidate_left < left {
          next.push((candidate_left, left.min(candidate_right)))
        }
        if candidate_right > right {
          next.push((right.max(candidate_left), candidate_right))
        }
      }
    }
    remaining = next
    if remaining.is_empty() {
      break
    }
  }
  let mut new_bytes = 0L
  for candidate in remaining {
    new_bytes += candidate.1 - candidate.0
  }
  let mut merged_start = start
  let mut merged_end = end
  let merged : Array[(Int64, Int64)] = []
  for existing in self.recv_ranges {
    if existing.1 < merged_start || existing.0 > merged_end {
      merged.push(existing)
    } else {
      merged_start = merged_start.min(existing.0)
      merged_end = merged_end.max(existing.1)
    }
  }
  merged.push((merged_start, merged_end))
  self.recv_ranges = merged
  new_bytes
}

///|
pub(all) enum QuicAction {
  SendFrame(QuicFrame)
  StreamData(Int64, Bytes, Bool)
  StreamReset(Int64, Int64)
  ConnectionError(Int64, String)
  PeerAck(AckFrame)
  PacketIgnored
} derive(Eq, Debug)

///|
pub(all) struct QuicEndpoint {
  endpoint : @transport.Endpoint
  connection_id : ConnectionId
} derive(Eq, Debug)

///|
pub fn QuicEndpoint::new(
  endpoint : @transport.Endpoint,
  connection_id : ConnectionId,
) -> QuicEndpoint {
  { endpoint, connection_id, }
}

///|
pub fn QuicEndpoint::endpoint(self : QuicEndpoint) -> @transport.Endpoint {
  self.endpoint
}

///|
pub fn QuicEndpoint::connection_id(self : QuicEndpoint) -> ConnectionId {
  self.connection_id
}

///|
pub(all) struct QuicConnection {
  role : QuicRole
  mut state : QuicConnectionState
  limits : QuicLimits
  transport_params : QuicTransportParams
  streams : Map[Int64, QuicStreamState]
  mut connection_send_offset : Int64
  mut connection_recv_offset : Int64
  mut peer_max_data : Int64
  mut local_max_data : Int64
  mut next_stream_id : Int64
  mut close_error : (Int64, String)?
}

///|
pub fn QuicConnection::new(
  role : QuicRole,
  limits? : QuicLimits = QuicLimits::defaults(),
  transport_params? : QuicTransportParams = QuicTransportParams::defaults(),
) -> Result[QuicConnection, QuicError] {
  match limits.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match transport_params.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let first_stream = if role == Client { 0L } else { 1L }
  Ok({
    role,
    state: Handshaking,
    limits,
    transport_params,
    streams: Map([]),
    connection_send_offset: 0L,
    connection_recv_offset: 0L,
    peer_max_data: transport_params.initial_max_data.min(
      limits.max_connection_data,
    ),
    local_max_data: transport_params.initial_max_data.min(
      limits.max_connection_data,
    ),
    next_stream_id: first_stream,
    close_error: None,
  })
}

///|
pub fn QuicConnection::state(self : QuicConnection) -> QuicConnectionState {
  self.state
}

///|
pub fn QuicConnection::establish(
  self : QuicConnection,
) -> Result[Unit, QuicError] {
  if self.state == Closed || self.state == Draining {
    return Err(ConnectionClosed(0L, "connection is closing"))
  }
  self.state = Established
  Ok(())
}

///|
pub fn QuicConnection::open_bidirectional_stream(
  self : QuicConnection,
) -> Result[Int64, QuicError] {
  if self.state == Closed || self.state == Draining {
    return Err(ConnectionClosed(0L, "connection is not accepting streams"))
  }
  if self.state != Established {
    return Err(
      Unsupported("application streams require an established connection"),
    )
  }
  if self.streams.length() >= self.limits.max_streams ||
    self.streams.length().to_int64() >=
    self.transport_params.initial_max_streams_bidi {
    return Err(FlowControl(0L, "maximum bidirectional stream count reached"))
  }
  let id = self.next_stream_id
  if id > QUIC_MAX_VARINT - 4L {
    return Err(VarIntOverflow)
  }
  self.next_stream_id += 4L
  let stream = match
    quic_new_stream_state(
      id,
      self.transport_params.initial_max_stream_data_bidi_remote.min(
        self.limits.max_stream_data,
      ),
      self.transport_params.initial_max_stream_data_bidi_local.min(
        self.limits.max_stream_data,
      ),
      self.limits.max_stream_data.to_int(),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  self.streams.set(id, stream)
  Ok(id)
}

///|
pub fn QuicConnection::send_stream(
  self : QuicConnection,
  stream_id : Int64,
  data : Bytes,
  fin : Bool,
) -> Result[QuicFrame, QuicError] {
  if data.length() > self.limits.max_frame_payload {
    return Err(LimitExceeded("stream frame", self.limits.max_frame_payload))
  }
  if self.state == Closed || self.state == Draining {
    return Err(ConnectionClosed(0L, "connection is closed"))
  }
  if self.state != Established {
    return Err(
      Unsupported("application streams require an established connection"),
    )
  }
  guard self.streams.get(stream_id) is Some(stream) else {
    return Err(StreamClosed(stream_id))
  }
  if stream.reset || stream.fin_sent {
    return Err(StreamClosed(stream_id))
  }
  let length = data.length().to_int64()
  if length > stream.send_max - stream.send_offset {
    return Err(FlowControl(stream_id, "stream send window exhausted"))
  }
  if length > self.peer_max_data - self.connection_send_offset {
    return Err(FlowControl(0L, "connection send window exhausted"))
  }
  if stream.send_offset > QUIC_MAX_VARINT - length ||
    self.connection_send_offset > QUIC_MAX_VARINT - length {
    return Err(VarIntOverflow)
  }
  let offset = stream.send_offset
  stream.send_offset += length
  self.connection_send_offset += length
  stream.fin_sent = fin
  let frame = match StreamFrame::new(stream_id, offset, data, fin) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok(Stream(frame))
}

///|
pub fn QuicConnection::receive_frame(
  self : QuicConnection,
  frame : QuicFrame,
) -> Result[Array[QuicAction], QuicError] {
  if self.state == Closed {
    return Err(ConnectionClosed(0L, "connection is closed"))
  }
  let actions : Array[QuicAction] = []
  match frame {
    Ack(ack) => actions.push(PeerAck(ack))
    Stream(stream_frame) => {
      let id = stream_frame.stream_id
      if id < 0L ||
        (id & 2L) != 0L ||
        (self.role == Client && (id & 1L) == 0L) ||
        (self.role == Server && (id & 1L) != 1L) {
        return Err(Protocol(0x5L, "invalid peer bidirectional stream ID"))
      }
      let stream = match self.streams.get(id) {
        Some(value) => value
        None => {
          if self.streams.length() >= self.limits.max_streams {
            return Err(FlowControl(id, "maximum stream count reached"))
          }
          let value = match
            quic_new_stream_state(
              id,
              self.transport_params.initial_max_stream_data_bidi_remote.min(
                self.limits.max_stream_data,
              ),
              self.transport_params.initial_max_stream_data_bidi_local.min(
                self.limits.max_stream_data,
              ),
              self.limits.max_stream_data.to_int(),
            ) {
            Ok(result) => result
            Err(error) => return Err(error)
          }
          self.streams.set(id, value)
          value
        }
      }
      if stream.reset {
        return Err(StreamClosed(id))
      }
      let length = stream_frame.data.length().to_int64()
      if stream_frame.offset > QUIC_MAX_VARINT - length {
        return Err(VarIntOverflow)
      }
      let end = stream_frame.offset + length
      match stream.recv_final_size {
        Some(final_size) if stream_frame.fin && end != final_size =>
          return Err(FlowControl(id, "final stream size changed"))
        Some(final_size) if end > final_size =>
          return Err(FlowControl(id, "data exceeds final stream size"))
        _ => ()
      }
      if end > stream.recv_max {
        return Err(FlowControl(id, "stream receive window exceeded"))
      }
      let previous_ranges = stream.recv_ranges.copy()
      let new_bytes = stream.insert_received_range(stream_frame.offset, end)
      if new_bytes > self.local_max_data - self.connection_recv_offset {
        stream.recv_ranges = previous_ranges
        return Err(FlowControl(0L, "connection receive window exceeded"))
      }
      let chunks = match
        stream.reassembler.feed_bounded(
          stream_frame.offset,
          stream_frame.data,
          "STREAM reassembly",
        ) {
        Ok(value) => value
        Err(error) => {
          stream.recv_ranges = previous_ranges
          return Err(error)
        }
      }
      stream.recv_offset = end.max(stream.recv_offset)
      if stream_frame.fin {
        match stream.recv_final_size {
          Some(_) => ()
          None => stream.recv_final_size = Some(end)
        }
      }
      self.connection_recv_offset += new_bytes
      let complete = stream.recv_final_size ==
        Some(stream.reassembler.next_offset())
      for index, chunk in chunks {
        let fin = complete && index == chunks.length() - 1
        actions.push(StreamData(id, chunk, fin))
      }
      if complete && !stream.fin_received {
        stream.fin_received = true
        if chunks.is_empty() {
          actions.push(StreamData(id, b"", true))
        }
      }
    }
    MaxData(value) =>
      // RFC 9000 requires non-increasing MAX_DATA frames to be ignored. The
      // configured resource ceiling remains authoritative even if the peer
      // advertises a larger window.
      if value > self.peer_max_data {
        self.peer_max_data = value.min(self.limits.max_connection_data)
      }
    MaxStreamData(id, value) => {
      guard self.streams.get(id) is Some(stream) else {
        return Err(StreamClosed(id))
      }
      if value > stream.send_max {
        stream.send_max = value.min(self.limits.max_stream_data)
      }
    }
    ResetStream(id, code, final_size) => {
      guard self.streams.get(id) is Some(stream) else {
        return Err(StreamClosed(id))
      }
      if final_size < stream.recv_offset || final_size > stream.recv_max {
        return Err(FlowControl(id, "invalid RESET_STREAM final size"))
      }
      match stream.recv_final_size {
        Some(previous) if previous != final_size =>
          return Err(FlowControl(id, "RESET_STREAM final size changed"))
        _ => stream.recv_final_size = Some(final_size)
      }
      stream.reset = true
      actions.push(StreamReset(id, code))
    }
    ConnectionClose(_, code, _, reason) => {
      self.state = Draining
      let text = @utf8.decode_lossy(reason)
      self.close_error = Some((code, text))
      actions.push(ConnectionError(code, text))
    }
    _ => ()
  }
  Ok(actions)
}
