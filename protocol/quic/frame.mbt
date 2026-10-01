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
