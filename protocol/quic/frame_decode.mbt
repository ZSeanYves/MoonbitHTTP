///|
priv struct QuicFrameReader {
  mut remaining : BytesView
}

///|
fn QuicFrameReader::varint(
  self : QuicFrameReader,
  canonical? : Bool = false,
) -> Int64 raise QuicError {
  let (value, used) = quic_decode_varint(self.remaining, canonical~).unwrap_or_error()
  self.remaining = self.remaining[used:]
  value.value()
}

///|
fn QuicFrameReader::index(
  self : QuicFrameReader,
  canonical? : Bool = false,
) -> Int raise QuicError {
  varint_to_index(self.varint(canonical~)).unwrap_or_error()
}

///|
fn QuicFrameReader::take(
  self : QuicFrameReader,
  count : Int,
) -> BytesView raise QuicError {
  if count > self.remaining.length() {
    raise NeedMoreInput
  }
  let value = self.remaining[:count]
  self.remaining = self.remaining[count:]
  value
}

///|
fn QuicFrameReader::ack(
  self : QuicFrameReader,
  with_ecn : Bool,
  limits : QuicLimits,
) -> AckFrame raise QuicError {
  let largest = self.varint()
  let delay = self.varint()
  let count = self.index()
  if count > limits.max_ack_ranges {
    raise LimitExceeded("ACK ranges", limits.max_ack_ranges)
  }
  let first = self.varint()
  if first > largest {
    raise InvalidFrame("ACK first range underflows")
  }
  let mut smallest = largest - first
  let ranges : Array[AckRange] = [{ largest, smallest, }]
  for _ in 0..<count {
    let gap = self.varint()
    let length = self.varint()
    if gap + 2L > smallest {
      raise InvalidFrame("ACK range gap underflows packet number")
    }
    let largest = smallest - gap - 2L
    if length > largest {
      raise InvalidFrame("ACK range length underflows packet number")
    }
    smallest = largest - length
    ranges.push({ largest, smallest, })
  }
  let ecn_counts = if with_ecn {
    let ect0 = self.varint()
    let ect1 = self.varint()
    let ce = self.varint()
    Some((ect0, ect1, ce))
  } else {
    None
  }
  { largest_acknowledged: largest, ack_delay: delay, ranges, ecn_counts, }
}

///|
fn QuicFrameReader::frame(
  self : QuicFrameReader,
  limits : QuicLimits,
) -> QuicFrame raise QuicError {
  let typ = self.index(canonical=true)
  match typ {
    0x00 => Padding
    0x01 => Ping
    0x02 | 0x03 => Ack(self.ack(typ == 0x03, limits))
    0x04 => {
      let id = self.varint()
      let code = self.varint()
      ResetStream(id, code, self.varint())
    }
    0x05 => {
      let id = self.varint()
      StopSending(id, self.varint())
    }
    0x06 => {
      let offset = self.varint()
      let length = self.index()
      if length > limits.max_crypto_bytes {
        raise LimitExceeded("CRYPTO data", limits.max_crypto_bytes)
      }
      ignore(quic_range_end(offset, length).unwrap_or_error())
      Crypto(offset, self.take(length).to_owned())
    }
    0x07 => {
      let length = self.index()
      quic_check_new_token(length)
      NewToken(self.take(length).to_owned())
    }
    _ if typ >= 0x08 && typ <= 0x0f => {
      let id = self.varint()
      let offset = if (typ & 0x04) != 0 { self.varint() } else { 0L }
      let length = if (typ & 0x02) != 0 {
        self.index()
      } else {
        self.remaining.length()
      }
      let data = self.take(length).to_owned()
      Stream(
        StreamFrame::new(id, offset, data, (typ & 0x01) != 0).unwrap_or_error(),
      )
    }
    0x10 => MaxData(self.varint())
    0x11 => {
      let id = self.varint()
      MaxStreamData(id, self.varint())
    }
    0x12 | 0x13 => {
      let count = self.varint()
      quic_check_stream_count(count)
      MaxStreams(typ == 0x13, count)
    }
    0x14 => DataBlocked(self.varint())
    0x15 => {
      let id = self.varint()
      StreamDataBlocked(id, self.varint())
    }
    0x16 | 0x17 => {
      let count = self.varint()
      quic_check_stream_count(count)
      StreamsBlocked(typ == 0x17, count)
    }
    0x18 => {
      let sequence = self.varint()
      let floor = self.varint()
      let length = self.take(1)[0].to_int()
      if !quic_valid_connection_id_announcement(sequence, floor, length, 16) {
        raise Protocol(0x07L, "invalid NEW_CONNECTION_ID")
      }
      let fields = self.take(length + 16)
      let id : ConnectionId = { bytes: fields[:length].to_owned(), }
      NewConnectionId(sequence, floor, id, fields[length:].to_owned())
    }
    0x19 => RetireConnectionId(self.varint())
    0x1a => PathChallenge(self.take(8).to_owned())
    0x1b => PathResponse(self.take(8).to_owned())
    0x1c | 0x1d => {
      let code = self.varint()
      let transport = typ == 0x1c
      let frame_type = if transport { self.varint() } else { 0L }
      let length = self.index()
      ConnectionClose(transport, code, frame_type, self.take(length).to_owned())
    }
    0x1e => HandshakeDone
    0x30 | 0x31 => {
      let length = if typ == 0x31 {
        self.index()
      } else {
        self.remaining.length()
      }
      Datagram(self.take(length).to_owned())
    }
    _ => raise InvalidFrame("unknown QUIC frame type")
  }
}

///|
pub fn quic_decode_frames(
  payload : BytesView,
  limits? : QuicLimits = QuicLimits::defaults(),
) -> Result[Array[QuicFrame], QuicError] {
  try {
    limits.validate().unwrap_or_error()
    Ok(quic_read_frames(payload, limits))
  } catch {
    error => Err(error)
  }
}

///|
/// Driver construction validates the immutable configuration. Each packet
/// still has its payload, fields, lengths and resource bounds checked here.
fn quic_read_frames(
  payload : BytesView,
  limits : QuicLimits,
) -> Array[QuicFrame] raise QuicError {
  if payload.length() > limits.max_frame_payload {
    raise LimitExceeded("frame payload", limits.max_frame_payload)
  }
  let reader : QuicFrameReader = { remaining: payload, }
  let frames = []
  while !reader.remaining.is_empty() {
    frames.push(reader.frame(limits))
  }
  frames
}
