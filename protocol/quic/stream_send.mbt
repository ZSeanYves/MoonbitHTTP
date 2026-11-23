///|
priv enum StreamWrite {
  Data(BytesView, Bool, Int32?)
  Reset(Int64)
}

///|
/// Commit stream offsets and terminal state only after the transport accepts
/// the frame. A rejected packet can be retried on the same stream.
fn[T] QuicConnection::write_stream(
  self : QuicConnection,
  id : Int64,
  write : StreamWrite,
  emit : (QuicFrame, Int32) -> Result[T, QuicError],
) -> Result[T, QuicError] {
  match self.state {
    Closed | Draining =>
      return Err(ConnectionClosed(0L, "connection is closed"))
    Handshaking =>
      return Err(
        Unsupported("application streams require an established connection"),
      )
    Established => ()
  }
  guard self.streams.get(id) is Some(stream) else {
    return Err(StreamClosed(id))
  }
  if (id & 2L) != 0L && !self.locally_initiated(id) {
    return Err(Protocol(0x5L, "cannot send on peer unidirectional stream"))
  }
  let (frame, length, finished) = match write {
    Reset(code) => {
      if !stream.can_reset_send() {
        return Err(StreamClosed(id))
      }
      if code < 0L || code > QUIC_MAX_VARINT {
        return Err(InvalidFrame("invalid RESET_STREAM application error code"))
      }
      (QuicFrame::ResetStream(id, code, stream.send_offset), 0L, true)
    }
    Data(data, fin, packet_budget) => {
      guard stream.send_state is Writable else { return Err(StreamClosed(id)) }
      let offered = match packet_budget {
        None => {
          if data.length() > self.limits.max_frame_payload {
            return Err(
              LimitExceeded("stream frame", self.limits.max_frame_payload),
            )
          }
          data.length()
        }
        Some(budget) => {
          // STREAM is encoded with explicit offset and length. Reserve a length
          // varint wide enough for any payload fitting the current packet.
          let room = budget -
            1 -
            quic_encoded_varint_size(id) -
            quic_encoded_varint_size(stream.send_offset)
          let available = room -
            quic_encoded_varint_size(room.max(0).to_int64())
          if available < 0 || (available == 0 && !data.is_empty()) {
            return Err(LimitExceeded("QUIC STREAM packet budget", budget))
          }
          data.length().min(available)
        }
      }
      let stream_credit = (stream.send_max - stream.send_offset).min(
        self.limits.max_stream_data - stream.outstanding.bytes,
      )
      let connection_credit = (self.peer_max_data - self.connection_send_offset).min(
        self.limits.max_connection_data - self.retained_send_bytes,
      )
      let required = (if packet_budget is Some(_) {
        offered.min(1)
      } else {
        offered
      }).to_int64()
      if required > stream_credit {
        return Err(FlowControl(id, "stream send window exhausted"))
      }
      if required > connection_credit {
        return Err(FlowControl(0L, "connection send window exhausted"))
      }
      let length = offered.to_int64().min(stream_credit).min(connection_credit)
      let finished = fin && length == data.length().to_int64()
      (
        Stream({
          stream_id: id,
          offset: stream.send_offset,
          data: data[:length.to_int()].to_owned(),
          fin: finished,
        }),
        length,
        finished,
      )
    }
  }
  let result = match emit(frame, length.to_int()) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match write {
    Reset(_) => self.commit_send_reset(stream)
    Data(_, _, _) => {
      stream.outstanding.append(stream.send_offset, length)
      stream.send_offset += length
      self.connection_send_offset += length
      self.retained_send_bytes += length
      if finished {
        stream.send_state = FinSent(false)
      }
    }
  }
  Ok(result)
}

///|
fn QuicConnection::commit_send_reset(
  self : QuicConnection,
  stream : QuicStreamState,
) -> Unit {
  self.retained_send_bytes -= stream.outstanding.bytes
  stream.outstanding.ranges.clear()
  stream.outstanding.bytes = 0L
  stream.send_state = ResetSent
}

///|
/// Hand a STREAM frame to a custom reliable transport. The caller owns the
/// returned frame until it is acknowledged or the connection terminates.
pub fn QuicConnection::send_stream(
  self : QuicConnection,
  stream_id : Int64,
  data : Bytes,
  fin : Bool,
) -> Result[QuicFrame, QuicError] {
  self.write_stream(stream_id, Data(data, fin, None), fn(frame, _) { Ok(frame) })
}

///|
/// End the sending direction using the number of bytes already handed off.
pub fn QuicConnection::reset_stream(
  self : QuicConnection,
  stream_id : Int64,
  code : Int64,
) -> Result[QuicFrame, QuicError] {
  self.write_stream(stream_id, Reset(code), fn(frame, _) { Ok(frame) })
}

///|
/// Build one STREAM packet and register it with recovery before advancing
/// the stream. Split payloads to fit the negotiated datagram size.
pub fn QuicDatagramDriver::send_stream(
  self : QuicDatagramDriver,
  stream_id : Int64,
  data : Bytes,
  fin : Bool,
  now_ms : Int64,
) -> Result[QuicDriverAction, QuicError] {
  self.connection.write_stream(stream_id, Data(data, fin, None), fn(frame, _) {
    self.send_frames(Application, [frame], now_ms)
  })
}

///|
/// Send a prefix that fits the packet and both flow-control windows. The count
/// advances only when the returned datagram is handed to recovery. Retry the
/// remaining view after ACKs, credit updates or a timer. None means temporarily
/// blocked. An empty view with fin=true can send a zero-byte FIN.
pub fn QuicDatagramDriver::send_stream_prefix(
  self : QuicDatagramDriver,
  stream_id : Int64,
  data : BytesView,
  fin : Bool,
  now_ms : Int64,
) -> Result[(Int32, QuicDriverAction)?, QuicError] {
  let write = Data(data, fin, Some(self.application_payload_limit()))
  match
    self.connection.write_stream(stream_id, write, fn(frame, count) {
      self
      .send_frames(Application, [frame], now_ms)
      .map(action => (count, action))
    }) {
    Ok(sent) => Ok(Some(sent))
    Err(error) if error.send_blocked() => Ok(None)
    Err(error) => Err(error)
  }
}

///|
/// True when a later ACK, credit update or path validation can unblock a send.
pub fn QuicError::send_blocked(self : QuicError) -> Bool {
  match self {
    AmplificationBlocked
    | FlowControl(_, _)
    | LimitExceeded("QUIC retransmission queue", _)
    | LimitExceeded("QUIC recovery packet queue", _) => true
    _ => false
  }
}

///|
/// Send a reliable RESET_STREAM with the sending direction's final size.
pub fn QuicDatagramDriver::reset_stream(
  self : QuicDatagramDriver,
  stream_id : Int64,
  code : Int64,
  now_ms : Int64,
) -> Result[QuicDriverAction, QuicError] {
  self.connection.write_stream(stream_id, Reset(code), fn(frame, _) {
    self
    .send_frames(Application, [frame], now_ms)
    .map(action => {
      self.discard_stream_retransmissions(stream_id)
      action
    })
  })
}

///|
/// A custom reliable transport reports acknowledged byte ranges. Reordering,
/// duplicate ACKs and retransmissions with different frame boundaries release
/// only bytes still outstanding. QuicDatagramDriver performs this on packet ACK.
pub fn QuicConnection::acknowledge_stream_data(
  self : QuicConnection,
  id : Int64,
  offset : Int64,
  length : Int32,
  fin~ : Bool = false,
) -> Result[Unit, QuicError] {
  let end = match quic_range_end(offset, length) {
    Ok(end) => end
    Err(_) => return Err(InvalidFrame("invalid acknowledged stream range"))
  }
  if self.is_retired(id) {
    return Ok(())
  }
  guard self.streams.get(id) is Some(stream) else {
    return Err(StreamClosed(id))
  }
  if end > stream.send_offset {
    return Err(InvalidFrame("acknowledged unsent stream data"))
  }
  if fin {
    if end != stream.send_offset || stream.send_state is Writable {
      return Err(InvalidFrame("acknowledged unsent stream FIN"))
    }
    if stream.send_state is FinSent(_) {
      stream.send_state = FinSent(true)
    }
  }
  self.retained_send_bytes -= stream.outstanding.release(offset, end)
  self.retire_if_finished(id, stream)
  Ok(())
}

///|
/// Report delivery of a frame handed to a custom reliable transport; this
/// accounts for zero-length FINs and RESET_STREAM as well as byte ranges.
pub fn QuicConnection::acknowledge_stream_frame(
  self : QuicConnection,
  frame : QuicFrame,
) -> Result[Unit, QuicError] {
  match frame {
    Stream(data) =>
      self.acknowledge_stream_data(
        data.stream_id,
        data.offset,
        data.data.length(),
        fin=data.fin,
      )
    ResetStream(id, _, size) => {
      if self.is_retired(id) {
        return Ok(())
      }
      guard self.streams.get(id) is Some(stream) else {
        return Err(StreamClosed(id))
      }
      guard stream.send_state is (ResetSent | ResetAcknowledged) &&
        size == stream.send_offset else {
        return Err(InvalidFrame("acknowledged unsent stream reset"))
      }
      stream.send_state = ResetAcknowledged
      self.retire_if_finished(id, stream)
      Ok(())
    }
    _ => Ok(())
  }
}

///|
/// Whether the local sending direction can accept another application write.
/// Flow control and congestion are checked when a write is submitted.
pub fn QuicConnection::stream_writable(
  self : QuicConnection,
  id : Int64,
) -> Bool {
  self.state == Established &&
  ((id & 2L) == 0L || self.locally_initiated(id)) &&
  self.streams.get(id) is Some(stream) &&
  stream.send_state is Writable
}

///|
/// Whether stream bytes, a FIN or a RESET_STREAM still await acknowledgment.
pub fn QuicConnection::stream_writes_pending(self : QuicConnection) -> Bool {
  if self.retained_send_bytes != 0L {
    return true
  }
  for _, stream in self.streams {
    if stream.send_state is (FinSent(false) | ResetSent) {
      return true
    }
  }
  false
}
