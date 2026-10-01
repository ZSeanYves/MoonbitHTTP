///|
/// A bounded CRYPTO reassembler.  TLS handshake bytes are carried in QUIC
/// CRYPTO frames and may arrive fragmented, duplicated, or out of order.  The
/// reassembler only releases contiguous bytes, so a TLS facade never has to
/// guess whether a gap is a record boundary.
pub struct QuicCryptoReassembler {
  priv mut next_offset : Int64
  priv mut segments : Array[(Int64, Bytes)]
  priv delivered : Array[Byte]
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
    delivered: [],
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
  match
    self.charge_work(
      data.length().to_int64() + self.segments.length().to_int64(),
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
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
        Err(error) => return Err(error)
      }
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
