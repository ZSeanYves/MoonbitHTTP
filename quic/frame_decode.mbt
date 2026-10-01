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
