///|
priv enum StreamWrite {
  Data(Bytes, Bool)
  Reset(Int64)
}

///|
/// Commit stream offsets and terminal state only after the transport accepts
/// the frame. A rejected packet can be retried on the same stream.
fn[T] QuicConnection::write_stream(
  self : QuicConnection,
  id : Int64,
  write : StreamWrite,
  emit : (QuicFrame) -> Result[T, QuicError],
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
  if stream.fin_sent {
    return Err(StreamClosed(id))
  }
  let (frame, length, finished) = match write {
    Reset(code) => {
      if code < 0L || code > QUIC_MAX_VARINT {
        return Err(InvalidFrame("invalid RESET_STREAM application error code"))
      }
      (QuicFrame::ResetStream(id, code, stream.send_offset), 0L, true)
    }
    Data(data, fin) => {
      if data.length() > self.limits.max_frame_payload {
        return Err(LimitExceeded("stream frame", self.limits.max_frame_payload))
      }
      let length = data.length().to_int64()
      if length > stream.send_max - stream.send_offset ||
        length > self.limits.max_stream_data - stream.outstanding.bytes {
        return Err(FlowControl(id, "stream send window exhausted"))
      }
      if length > self.peer_max_data - self.connection_send_offset ||
        length > self.limits.max_connection_data - self.retained_send_bytes {
        return Err(FlowControl(0L, "connection send window exhausted"))
      }
      (
        Stream({ stream_id: id, offset: stream.send_offset, data, fin, }),
        length,
        fin,
      )
    }
  }
  let result = match emit(frame) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  stream.outstanding.append(stream.send_offset, length)
  stream.send_offset += length
  self.connection_send_offset += length
  self.retained_send_bytes += length
  stream.fin_sent = finished
  self.retire_if_finished(id, stream)
  Ok(result)
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
  self.write_stream(stream_id, Data(data, fin), fn(frame) { Ok(frame) })
}

///|
/// End the sending direction using the number of bytes already handed off.
pub fn QuicConnection::reset_stream(
  self : QuicConnection,
  stream_id : Int64,
  code : Int64,
) -> Result[QuicFrame, QuicError] {
  self.write_stream(stream_id, Reset(code), fn(frame) { Ok(frame) })
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
  self.connection.write_stream(stream_id, Data(data, fin), fn(frame) {
    self.send_frames(Application, [frame], now_ms)
  })
}

///|
/// Send a reliable RESET_STREAM with the sending direction's final size.
pub fn QuicDatagramDriver::reset_stream(
  self : QuicDatagramDriver,
  stream_id : Int64,
  code : Int64,
  now_ms : Int64,
) -> Result[QuicDriverAction, QuicError] {
  self.connection.write_stream(stream_id, Reset(code), fn(frame) {
    self.send_frames(Application, [frame], now_ms)
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
  length : Int,
) -> Result[Unit, QuicError] {
  if offset < 0L || length < 0 || offset > QUIC_MAX_VARINT - length.to_int64() {
    return Err(InvalidFrame("invalid acknowledged stream range"))
  }
  if self.is_retired(id) {
    return Ok(())
  }
  guard self.streams.get(id) is Some(stream) else {
    return Err(StreamClosed(id))
  }
  let end = offset + length.to_int64()
  if end > stream.send_offset {
    return Err(InvalidFrame("acknowledged unsent stream data"))
  }
  self.retained_send_bytes -= stream.outstanding.release(offset, end)
  Ok(())
}
