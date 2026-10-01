///|
/// QUIC frame encoding lives beside the decoder so a driver can round-trip
/// frames without reimplementing wire rules.  Every integer is encoded in its
/// canonical variable-length form and all byte lengths are checked before a
/// buffer is allocated.

///|
fn quic_frame_join(parts : Array[Bytes]) -> Bytes {
  let mut length = 0
  for part in parts {
    if part.length() > @int.MAX_VALUE - length {
      return b""
    }
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
fn quic_frame_varint(value : Int64) -> Result[Bytes, QuicError] {
  match QuicVarInt::new(value) {
    Ok(encoded) => Ok(encoded.encode())
    Err(error) => Err(error)
  }
}

///|
fn quic_frame_bytes_length(
  value : Int,
  label : String,
) -> Result[Bytes, QuicError] {
  if value < 0 || value > @int.MAX_VALUE {
    return Err(LimitExceeded(label, value))
  }
  quic_frame_varint(value.to_int64())
}

///|
fn quic_encode_ack(ack : AckFrame, with_ecn : Bool) -> Result[Bytes, QuicError] {
  if ack.ranges.is_empty() ||
    ack.largest_acknowledged < 0L ||
    ack.ack_delay < 0L {
    return Err(InvalidFrame("invalid ACK frame"))
  }
  let first = ack.ranges[0]
  if first.largest != ack.largest_acknowledged {
    return Err(InvalidFrame("ACK largest value does not match first range"))
  }
  let mut previous_smallest = first.smallest
  if first.largest - first.smallest < 0L {
    return Err(InvalidFrame("invalid ACK range"))
  }
  let parts : Array[Bytes] = [
    quic_frame_varint(ack.largest_acknowledged).unwrap(),
    quic_frame_varint(ack.ack_delay).unwrap(),
    quic_frame_varint((ack.ranges.length() - 1).to_int64()).unwrap(),
    quic_frame_varint(first.largest - first.smallest).unwrap(),
  ]
  for index in 1..<ack.ranges.length() {
    let range = ack.ranges[index]
    if range.largest >= previous_smallest ||
      range.smallest < 0L ||
      range.largest < range.smallest {
      return Err(InvalidFrame("ACK ranges overlap or are unordered"))
    }
    let gap = previous_smallest - range.largest - 2L
    if gap < 0L {
      return Err(InvalidFrame("ACK range gap underflows"))
    }
    parts.push(quic_frame_varint(gap).unwrap())
    parts.push(quic_frame_varint(range.largest - range.smallest).unwrap())
    previous_smallest = range.smallest
  }
  if with_ecn {
    match ack.ecn_counts {
      Some((ect0, ect1, ce)) if ect0 >= 0L && ect1 >= 0L && ce >= 0L => {
        parts.push(quic_frame_varint(ect0).unwrap())
        parts.push(quic_frame_varint(ect1).unwrap())
        parts.push(quic_frame_varint(ce).unwrap())
      }
      _ => return Err(InvalidFrame("invalid ECN counts"))
    }
  } else if ack.ecn_counts is Some(_) {
    return Err(InvalidFrame("ECN counts require ACK_ECN"))
  }
  Ok(quic_frame_join(parts))
}

///|
/// Encodes one QUIC frame.  The returned bytes are suitable for the
/// authenticated payload of a packet; packet protection is deliberately kept
/// in `packet_protection.mbt`.
pub fn quic_encode_frame(
  frame : QuicFrame,
  limits? : QuicLimits = QuicLimits::defaults(),
) -> Result[Bytes, QuicError] {
  match limits.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let encoded : Bytes = match frame {
    Padding => b"\x00"
    Ping => b"\x01"
    Ack(ack) => {
      let body = match quic_encode_ack(ack, ack.ecn_counts is Some(_)) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      quic_frame_join([
        quic_frame_varint(if ack.ecn_counts is Some(_) { 3L } else { 2L }).unwrap(),
        body,
      ])
    }
    ResetStream(stream_id, error_code, final_size) => {
      if stream_id < 0L || error_code < 0L || final_size < 0L {
        return Err(InvalidFrame("invalid RESET_STREAM"))
      }
      quic_frame_join([
        b"\x04",
        quic_frame_varint(stream_id).unwrap(),
        quic_frame_varint(error_code).unwrap(),
        quic_frame_varint(final_size).unwrap(),
      ])
    }
    StopSending(stream_id, error_code) => {
      if stream_id < 0L || error_code < 0L {
        return Err(InvalidFrame("invalid STOP_SENDING"))
      }
      quic_frame_join([
        b"\x05",
        quic_frame_varint(stream_id).unwrap(),
        quic_frame_varint(error_code).unwrap(),
      ])
    }
    Crypto(offset, data) => {
      if offset < 0L || data.length() > limits.max_crypto_bytes {
        return Err(LimitExceeded("CRYPTO data", limits.max_crypto_bytes))
      }
      quic_frame_join([
        b"\x06",
        quic_frame_varint(offset).unwrap(),
        quic_frame_bytes_length(data.length(), "CRYPTO data").unwrap(),
        data,
      ])
    }
    NewToken(token) => {
      if token.length() > limits.max_frame_payload {
        return Err(LimitExceeded("NEW_TOKEN", limits.max_frame_payload))
      }
      quic_frame_join([
        b"\x07",
        quic_frame_bytes_length(token.length(), "NEW_TOKEN").unwrap(),
        token,
      ])
    }
    Stream(stream_frame) => {
      let data = stream_frame.data
      if stream_frame.stream_id < 0L ||
        stream_frame.offset < 0L ||
        data.length() > limits.max_frame_payload {
        return Err(LimitExceeded("STREAM data", limits.max_frame_payload))
      }
      let typ = if stream_frame.fin { 0x0fL } else { 0x0eL }
      quic_frame_join([
        quic_frame_varint(typ).unwrap(),
        quic_frame_varint(stream_frame.stream_id).unwrap(),
        quic_frame_varint(stream_frame.offset).unwrap(),
        quic_frame_bytes_length(data.length(), "STREAM data").unwrap(),
        data,
      ])
    }
    MaxData(value) => {
      if value < 0L {
        return Err(InvalidFrame("invalid MAX_DATA"))
      }
      quic_frame_join([b"\x10", quic_frame_varint(value).unwrap()])
    }
    MaxStreamData(stream_id, value) => {
      if stream_id < 0L || value < 0L {
        return Err(InvalidFrame("invalid MAX_STREAM_DATA"))
      }
      quic_frame_join([
        b"\x11",
        quic_frame_varint(stream_id).unwrap(),
        quic_frame_varint(value).unwrap(),
      ])
    }
    MaxStreams(bidi, value) => {
      if value < 0L {
        return Err(InvalidFrame("invalid MAX_STREAMS"))
      }
      quic_frame_join([
        quic_frame_varint(if bidi { 0x13L } else { 0x12L }).unwrap(),
        quic_frame_varint(value).unwrap(),
      ])
    }
    DataBlocked(value) => {
      if value < 0L {
        return Err(InvalidFrame("invalid DATA_BLOCKED"))
      }
      quic_frame_join([b"\x14", quic_frame_varint(value).unwrap()])
    }
    StreamDataBlocked(stream_id, value) => {
      if stream_id < 0L || value < 0L {
        return Err(InvalidFrame("invalid STREAM_DATA_BLOCKED"))
      }
      quic_frame_join([
        b"\x15",
        quic_frame_varint(stream_id).unwrap(),
        quic_frame_varint(value).unwrap(),
      ])
    }
    StreamsBlocked(bidi, value) => {
      if value < 0L {
        return Err(InvalidFrame("invalid STREAMS_BLOCKED"))
      }
      quic_frame_join([
        quic_frame_varint(if bidi { 0x17L } else { 0x16L }).unwrap(),
        quic_frame_varint(value).unwrap(),
      ])
    }
    NewConnectionId(sequence, retire_prior_to, id, token) => {
      if sequence < 0L ||
        retire_prior_to < 0L ||
        retire_prior_to > sequence ||
        id.bytes().is_empty() ||
        id.bytes().length() > QUIC_MAX_CONNECTION_ID ||
        token.length() != 16 {
        return Err(InvalidFrame("invalid NEW_CONNECTION_ID"))
      }
      quic_frame_join([
        b"\x18",
        quic_frame_varint(sequence).unwrap(),
        quic_frame_varint(retire_prior_to).unwrap(),
        Bytes::from_array([id.bytes().length().to_byte()]),
        id.bytes(),
        token,
      ])
    }
    RetireConnectionId(sequence) => {
      if sequence < 0L {
        return Err(InvalidFrame("invalid RETIRE_CONNECTION_ID"))
      }
      quic_frame_join([b"\x19", quic_frame_varint(sequence).unwrap()])
    }
    PathChallenge(data) => {
      if data.length() != 8 {
        return Err(InvalidFrame("PATH data must contain eight bytes"))
      }
      quic_frame_join([b"\x1a", data])
    }
    PathResponse(data) => {
      if data.length() != 8 {
        return Err(InvalidFrame("PATH data must contain eight bytes"))
      }
      quic_frame_join([b"\x1b", data])
    }
    ConnectionClose(transport_error, error_code, frame_type, reason) => {
      if error_code < 0L ||
        frame_type < 0L ||
        reason.length() > limits.max_frame_payload {
        return Err(InvalidFrame("invalid CONNECTION_CLOSE"))
      }
      if transport_error {
        quic_frame_join([
          b"\x1c",
          quic_frame_varint(error_code).unwrap(),
          quic_frame_varint(frame_type).unwrap(),
          quic_frame_bytes_length(reason.length(), "close reason").unwrap(),
          reason,
        ])
      } else {
        quic_frame_join([
          b"\x1d",
          quic_frame_varint(error_code).unwrap(),
          quic_frame_bytes_length(reason.length(), "close reason").unwrap(),
          reason,
        ])
      }
    }
    HandshakeDone => b"\x1e"
    Datagram(data) => {
      if data.length() > limits.max_frame_payload {
        return Err(LimitExceeded("DATAGRAM", limits.max_frame_payload))
      }
      quic_frame_join([
        b"\x31",
        quic_frame_bytes_length(data.length(), "DATAGRAM").unwrap(),
        data,
      ])
    }
  }
  if encoded.length() > limits.max_frame_payload {
    return Err(LimitExceeded("encoded QUIC frame", limits.max_frame_payload))
  }
  Ok(encoded)
}

///|
pub fn quic_encode_frames(
  frames : Array[QuicFrame],
  limits? : QuicLimits = QuicLimits::defaults(),
) -> Result[Bytes, QuicError] {
  let parts : Array[Bytes] = []
  let mut total = 0
  for frame in frames {
    let encoded = match quic_encode_frame(frame, limits~) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if encoded.length() > limits.max_frame_payload - total {
      return Err(LimitExceeded("encoded QUIC frames", limits.max_frame_payload))
    }
    total += encoded.length()
    parts.push(encoded)
  }
  Ok(quic_frame_join(parts))
}
