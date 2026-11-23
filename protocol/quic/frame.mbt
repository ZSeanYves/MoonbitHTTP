///|
#derive(Eq, Debug)
pub(all) struct AckRange {
  largest : Int64
  smallest : Int64
}

///|
pub fn AckRange::new(
  largest : Int64,
  smallest : Int64,
) -> Result[AckRange, QuicError] {
  let range : AckRange = { largest, smallest, }
  if !range.valid() {
    return Err(InvalidFrame("ACK range bounds are invalid"))
  }
  Ok(range)
}

///|
fn AckRange::valid(self : AckRange) -> Bool {
  self.smallest >= 0L &&
  self.smallest <= self.largest &&
  self.largest <= QUIC_MAX_VARINT
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
#derive(Eq, Debug)
pub(all) struct AckFrame {
  largest_acknowledged : Int64
  ack_delay : Int64
  ranges : Array[AckRange]
  ecn_counts : (Int64, Int64, Int64)?
}

///|
pub fn AckFrame::new(
  largest_acknowledged : Int64,
  ack_delay : Int64,
  ranges : Array[AckRange],
  ecn_counts~ : (Int64, Int64, Int64)? = None,
) -> Result[AckFrame, QuicError] {
  let ack : AckFrame = { largest_acknowledged, ack_delay, ranges, ecn_counts, }
  ack.validate() catch {
    error => return Err(error)
  }
  Ok(ack)
}

///|
fn AckFrame::validate(self : AckFrame) -> Unit raise QuicError {
  if self.ranges.is_empty() ||
    self.ranges[0].largest != self.largest_acknowledged {
    raise InvalidFrame("ACK largest value must match its first range")
  }
  ignore(QuicVarInt::new(self.ack_delay).unwrap_or_error())
  for i, range in self.ranges {
    if !range.valid() {
      raise InvalidFrame("ACK range bounds are invalid")
    }
    if i > 0 && range.largest > self.ranges[i - 1].smallest - 2L {
      raise InvalidFrame(
        "ACK ranges must descend with at least one missing packet",
      )
    }
  }
  if self.ecn_counts is Some((ect0, ect1, ce)) {
    ignore(QuicVarInt::new(ect0).unwrap_or_error())
    ignore(QuicVarInt::new(ect1).unwrap_or_error())
    ignore(QuicVarInt::new(ce).unwrap_or_error())
  }
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
#derive(Eq, Debug)
pub(all) struct StreamFrame {
  stream_id : Int64
  offset : Int64
  data : Bytes
  fin : Bool
}

///|
pub fn StreamFrame::new(
  stream_id : Int64,
  offset : Int64,
  data : Bytes,
  fin : Bool,
) -> Result[StreamFrame, QuicError] {
  if QuicVarInt::new(stream_id) is Err(error) {
    return Err(error)
  }
  if quic_range_end(offset, data.length()) is Err(error) {
    return Err(error)
  }
  Ok({ stream_id, offset, data, fin, })
}

///|
fn quic_range_end(offset : Int64, length : Int32) -> Result[Int64, QuicError] {
  if offset < 0L || length < 0 || offset > QUIC_MAX_VARINT - length.to_int64() {
    return Err(VarIntOverflow)
  }
  Ok(offset + length.to_int64())
}

///|
fn quic_check_stream_count(value : Int64) -> Unit raise QuicError {
  if value < 0L || value > QUIC_MAX_STREAM_COUNT {
    raise Protocol(0x07L, "stream count outside 0..2^60")
  }
}

///|
fn quic_check_new_token(length : Int32) -> Unit raise QuicError {
  if length == 0 {
    raise Protocol(0x07L, "NEW_TOKEN must carry a token")
  }
}

///|
fn quic_valid_connection_id_announcement(
  sequence : Int64,
  retire_prior_to : Int64,
  id_length : Int32,
  token_length : Int32,
) -> Bool {
  retire_prior_to >= 0L &&
  retire_prior_to <= sequence &&
  sequence <= QUIC_MAX_VARINT &&
  id_length >= 1 &&
  id_length <= QUIC_MAX_CONNECTION_ID &&
  token_length == 16
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
#derive(Eq, Debug)
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
}
