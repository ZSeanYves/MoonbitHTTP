///|
fn QuicConnection::discard_delivered(
  self : QuicConnection,
  stream : QuicStreamState,
) -> Unit {
  let count = stream.reassembler.delivered.length()
  stream.reassembler.consume(count)
  self.release_receive_credit(count.to_int64())
}

///|
fn[T] QuicConnection::stop_receiving(
  self : QuicConnection,
  id : Int64,
  code : Int64,
  emit : (QuicFrame) -> Result[T, QuicError],
) -> Result[T?, QuicError] {
  if self.state != Established {
    return Err(
      Unsupported("stopping a stream requires an established connection"),
    )
  }
  if code < 0L || code > QUIC_MAX_VARINT {
    return Err(InvalidFrame("invalid STOP_SENDING application error code"))
  }
  if (id & 2L) != 0L && self.locally_initiated(id) {
    return Err(Protocol(0x5L, "cannot stop receiving a send-only stream"))
  }
  if self.is_retired(id) {
    return Ok(None)
  }
  guard self.streams.get(id) is Some(stream) else {
    return Err(StreamClosed(id))
  }
  if stream.recv_stopped || stream.reset {
    return Ok(None)
  }
  let action = if stream.fin_received {
    None
  } else {
    match emit(StopSending(id, code)) {
      Ok(value) => Some(value)
      Err(error) => return Err(error)
    }
  }
  stream.recv_stopped = true
  self.pending_stream_credit.remove(id)
  self.discard_delivered(stream)
  Ok(action)
}

///|
/// Relinquish unread input and stop delivering new data for this receiving
/// half. Reliably send the returned frame. None means no wire action is needed.
pub fn QuicConnection::stop_sending(
  self : QuicConnection,
  id : Int64,
  code : Int64,
) -> Result[QuicFrame?, QuicError] {
  self.stop_receiving(id, code, frame => Ok(frame))
}

///|
/// A blocked packet leaves the receive direction untouched; retry after an ACK
/// or timer tick. Previously handed-off data and the peer's final size still
/// count toward connection flow control.
pub fn QuicDatagramDriver::stop_sending(
  self : QuicDatagramDriver,
  id : Int64,
  code : Int64,
  now_ms : Int64,
) -> Result[QuicDriverAction?, QuicError] {
  self.connection.stop_receiving(id, code, frame => {
    self.send_frames(Application, [frame], now_ms)
  })
}
