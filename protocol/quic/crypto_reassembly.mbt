///|
/// A bounded CRYPTO reassembler.  TLS handshake bytes are carried in QUIC
/// CRYPTO frames and may arrive fragmented, duplicated, or out of order.  The
/// reassembler only releases contiguous bytes, so a TLS facade never has to
/// guess whether a gap is a record boundary.
pub struct QuicCryptoReassembler {
  priv mut next_offset : Int64
  priv mut segments : Array[(Int64, Bytes)]
  priv delivered : @deque.Deque[Byte]
  priv max_bytes : Int
  priv max_segments : Int
  priv max_work : Int64
  priv mut work : Int64
} derive(Eq, Debug)

///|
pub fn QuicCryptoReassembler::new(
  max_bytes? : Int = 1024 * 1024,
  max_segments? : Int = 256,
  max_work? : Int64 = 64 * 1024 * 1024L,
) -> Result[QuicCryptoReassembler, QuicError] {
  if max_bytes < 0 {
    return Err(LimitExceeded("CRYPTO reassembly", max_bytes))
  }
  if max_segments < 0 || max_work < 0L {
    return Err(InvalidPacket("invalid CRYPTO reassembly work limits"))
  }
  Ok({
    next_offset: 0L,
    segments: [],
    delivered: @deque.from_array([]),
    max_bytes,
    max_segments,
    max_work,
    work: 0L,
  })
}

///|
fn QuicCryptoReassembler::charge_work(
  self : QuicCryptoReassembler,
  amount : Int64,
) -> Result[Unit, QuicError] {
  if amount > self.max_work - self.work {
    self.work = self.max_work
    return Err(
      LimitExceeded(
        "CRYPTO reassembly work",
        self.max_work.min(@int.MAX_VALUE.to_int64()).to_int(),
      ),
    )
  }
  self.work += amount
  Ok(())
}

///|
pub fn QuicCryptoReassembler::next_offset(
  self : QuicCryptoReassembler,
) -> Int64 {
  self.next_offset
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
  let end = match quic_range_end(offset, data.length()) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let history_start = self.history_start()
  if end - history_start > self.max_bytes.to_int64() {
    return Err(LimitExceeded(limit_name, self.max_bytes))
  }
  if data.is_empty() || end <= history_start {
    return Ok([])
  }
  match
    self.charge_work(
      data.length().to_int64() + self.segments.length().to_int64(),
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if offset < self.next_offset {
    let overlap_end = end.min(self.next_offset)
    for position in offset.max(history_start)..<overlap_end {
      let history_index = (position - history_start).to_int()
      if data[(position - offset).to_int()] != self.delivered[history_index] {
        return Err(Protocol(0x0aL, "conflicting retransmitted stream bytes"))
      }
    }
    if end <= self.next_offset {
      return Ok([])
    }
    let trim = (self.next_offset - offset).to_int()
    data = data[trim:].to_owned()
    offset = self.next_offset
  }
  if offset == self.next_offset && self.segments.is_empty() {
    return Ok(self.deliver(data))
  }
  // Compare every existing overlap before coalescing.  This is deliberately
  // byte based; handshake messages are not assumed to be aligned to frames.
  let mut touches_existing = false
  for existing in self.segments {
    let existing_end = existing.0 + existing.1.length().to_int64()
    if offset <= existing_end && end >= existing.0 {
      touches_existing = true
    }
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
  if !touches_existing &&
    offset > self.next_offset &&
    self.segments.length() >= self.max_segments {
    return Err(LimitExceeded("CRYPTO reassembly fragments", self.max_segments))
  }
  // Existing segments are already sorted. Insert once in linear time instead
  // of re-sorting all buffered fragments for every sparse one-byte input.
  self.segments.push((offset, data))
  let mut insertion = self.segments.length() - 1
  while insertion > 0 && self.segments[insertion - 1].0 > offset {
    self.segments[insertion] = self.segments[insertion - 1]
    insertion -= 1
  }
  self.segments[insertion] = (offset, data)
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
      match self.charge_work((last.1.length() + suffix.length()).to_int64()) {
        Ok(_) => ()
        Err(error) => {
          ignore(self.segments.remove(insertion))
          return Err(error)
        }
      }
      let combined = quic_driver_join([last.1, suffix])
      merged[last_index] = (last.0, combined)
    }
  }
  self.segments = merged
  // Coalesced ranges are disjoint and nonadjacent. Only their first member
  // can start at the delivery frontier.
  if merged is [(start, chunk), ..] && start == self.next_offset {
    ignore(merged.remove(0))
    return Ok(self.deliver(chunk))
  }
  Ok([])
}

///|
fn QuicCryptoReassembler::deliver(
  self : QuicCryptoReassembler,
  data : Bytes,
) -> Array[Bytes] {
  self.next_offset += data.length().to_int64()
  for byte in data {
    self.delivered.push_back(byte)
  }
  [data]
}

///|
fn QuicCryptoReassembler::history_start(self : QuicCryptoReassembler) -> Int64 {
  self.next_offset - self.delivered.length().to_int64()
}

///|
/// STREAM callers may release a contiguous delivered prefix after consumption.
/// CRYPTO keeps its full history and its original lifetime work budget.
fn QuicCryptoReassembler::consume(
  self : QuicCryptoReassembler,
  count : Int,
) -> Unit {
  if count == self.delivered.length() {
    self.delivered.clear()
  } else {
    for _ in 0..<count {
      ignore(self.delivered.pop_front())
    }
  }
  // Renew work in proportion to genuine forward progress; duplicates alone
  // cannot replenish the comparison/coalescing budget.
  self.work = (self.work - count.to_int64() * 64L).max(0L)
}

///|
fn QuicCryptoReassembler::discard(
  self : QuicCryptoReassembler,
  final_size : Int64,
) -> Unit {
  self.delivered.clear()
  self.delivered.shrink_to_fit()
  self.segments = []
  self.next_offset = final_size
}
