///|
priv struct QuicFrameWriter {
  output : @buffer.Buffer
  limits : QuicLimits
}

///|
fn QuicFrameWriter::put(
  self : QuicFrameWriter,
  data : Bytes,
) -> Unit raise QuicError {
  if data.length() > self.limits.max_frame_payload - self.output.length() {
    raise LimitExceeded("encoded QUIC payload", self.limits.max_frame_payload)
  }
  self.output.write_bytes(data)
}

///|
fn QuicFrameWriter::integer(
  self : QuicFrameWriter,
  value : Int64,
) -> Unit raise QuicError {
  self.put(QuicVarInt::new(value).unwrap_or_error().encode())
}

///|
fn QuicFrameWriter::length_prefixed(
  self : QuicFrameWriter,
  data : Bytes,
) -> Unit raise QuicError {
  self.integer(data.length().to_int64())
  self.put(data)
}

///|
fn QuicFrameWriter::ack(
  self : QuicFrameWriter,
  ack : AckFrame,
) -> Unit raise QuicError {
  let count = ack.ranges.length() - 1
  if count > self.limits.max_ack_ranges {
    raise LimitExceeded("ACK ranges", self.limits.max_ack_ranges)
  }
  ack.validate()
  self.put(if ack.ecn_counts is Some(_) { b"\x03" } else { b"\x02" })
  self.integer(ack.largest_acknowledged)
  self.integer(ack.ack_delay)
  self.integer(count.to_int64())
  let first = ack.ranges[0]
  self.integer(first.largest - first.smallest)
  let mut previous_smallest = first.smallest
  for i in 1..<ack.ranges.length() {
    let range = ack.ranges[i]
    self.integer(previous_smallest - range.largest - 2L)
    self.integer(range.largest - range.smallest)
    previous_smallest = range.smallest
  }
  if ack.ecn_counts is Some((ect0, ect1, ce)) {
    self.integer(ect0)
    self.integer(ect1)
    self.integer(ce)
  }
}

///|
fn QuicFrameWriter::frame(
  self : QuicFrameWriter,
  frame : QuicFrame,
) -> Unit raise QuicError {
  match frame {
    Padding => self.put(b"\x00")
    Ping => self.put(b"\x01")
    Ack(ack) => self.ack(ack)
    ResetStream(id, code, final_size) => {
      self.put(b"\x04")
      self.integer(id)
      self.integer(code)
      self.integer(final_size)
    }
    StopSending(id, code) => {
      self.put(b"\x05")
      self.integer(id)
      self.integer(code)
    }
    Crypto(offset, data) => {
      if data.length() > self.limits.max_crypto_bytes {
        raise LimitExceeded("CRYPTO data", self.limits.max_crypto_bytes)
      }
      ignore(quic_range_end(offset, data.length()).unwrap_or_error())
      self.put(b"\x06")
      self.integer(offset)
      self.length_prefixed(data)
    }
    NewToken(token) => {
      quic_check_new_token(token.length())
      self.put(b"\x07")
      self.length_prefixed(token)
    }
    Stream(stream) => {
      ignore(
        quic_range_end(stream.offset, stream.data.length()).unwrap_or_error(),
      )
      self.put(if stream.fin { b"\x0f" } else { b"\x0e" })
      self.integer(stream.stream_id)
      self.integer(stream.offset)
      self.length_prefixed(stream.data)
    }
    MaxData(value) => {
      self.put(b"\x10")
      self.integer(value)
    }
    MaxStreamData(id, value) => {
      self.put(b"\x11")
      self.integer(id)
      self.integer(value)
    }
    MaxStreams(uni, value) => {
      quic_check_stream_count(value)
      self.put(if uni { b"\x13" } else { b"\x12" })
      self.integer(value)
    }
    DataBlocked(value) => {
      self.put(b"\x14")
      self.integer(value)
    }
    StreamDataBlocked(id, value) => {
      self.put(b"\x15")
      self.integer(id)
      self.integer(value)
    }
    StreamsBlocked(uni, value) => {
      quic_check_stream_count(value)
      self.put(if uni { b"\x17" } else { b"\x16" })
      self.integer(value)
    }
    NewConnectionId(sequence, retire_prior_to, id, token) => {
      if !quic_valid_connection_id_announcement(
          sequence,
          retire_prior_to,
          id.bytes().length(),
          token.length(),
        ) {
        raise InvalidFrame("invalid NEW_CONNECTION_ID")
      }
      self.put(b"\x18")
      self.integer(sequence)
      self.integer(retire_prior_to)
      // A ConnectionId holds at most 20 bytes, so its length occupies one byte.
      self.length_prefixed(id.bytes())
      self.put(token)
    }
    RetireConnectionId(sequence) => {
      self.put(b"\x19")
      self.integer(sequence)
    }
    PathChallenge(data) | PathResponse(data) => {
      if data.length() != 8 {
        raise InvalidFrame("PATH data must contain eight bytes")
      }
      self.put(if frame is PathChallenge(_) { b"\x1a" } else { b"\x1b" })
      self.put(data)
    }
    ConnectionClose(transport_error, code, frame_type, reason) => {
      self.put(if transport_error { b"\x1c" } else { b"\x1d" })
      self.integer(code)
      if transport_error {
        self.integer(frame_type)
      } else if frame_type < 0L {
        raise InvalidFrame("invalid CONNECTION_CLOSE")
      }
      self.length_prefixed(reason)
    }
    HandshakeDone => self.put(b"\x1e")
    Datagram(data) => {
      self.put(b"\x31")
      self.length_prefixed(data)
    }
  }
}

///|
/// Encodes one frame into a canonical QUIC packet payload.
pub fn quic_encode_frame(
  frame : QuicFrame,
  limits? : QuicLimits = QuicLimits::defaults(),
) -> Result[Bytes, QuicError] {
  quic_encode_frames([frame], limits~)
}

///|
/// Checks the limits once and writes the entire payload within the byte budget.
pub fn quic_encode_frames(
  frames : Array[QuicFrame],
  limits? : QuicLimits = QuicLimits::defaults(),
) -> Result[Bytes, QuicError] {
  try {
    limits.validate().unwrap_or_error()
    let writer : QuicFrameWriter = { output: Buffer(), limits, }
    for frame in frames {
      writer.frame(frame)
    }
    Ok(writer.output.to_bytes())
  } catch {
    error => Err(error)
  }
}
