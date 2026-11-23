///|
fn QuicConnection::release_receive_credit(
  self : QuicConnection,
  count : Int64,
) -> Unit {
  self.released_receive_bytes += count.min(
    QUIC_MAX_VARINT - self.local_max_data - self.released_receive_bytes,
  )
}

///|
/// Report bytes already accepted by the application from StreamData events.
/// Each byte is consumed once. Passing zero or reporting a completed stream
/// after its retirement has no effect. Call poll() or take_credit_updates()
/// to transmit the resulting absolute flow-control limits.
pub fn QuicConnection::consume_stream_data(
  self : QuicConnection,
  id : Int64,
  count : Int32,
) -> Result[Unit, QuicError] {
  if count < 0 {
    return Err(InvalidFrame("negative consumption count"))
  }
  if self.is_retired(id) {
    return Ok(())
  }
  guard self.streams.get(id) is Some(stream) else {
    return Err(StreamClosed(id))
  }
  if stream.reset || stream.recv_stopped || count == 0 {
    return Ok(())
  }
  if count > stream.reassembler.delivered.length() {
    return Err(FlowControl(id, "consumption exceeds delivered stream data"))
  }
  stream.reassembler.consume(count)
  self.release_receive_credit(count.to_int64())
  if stream.recv_final_size is None {
    let consumed = stream.reassembler.history_start()
    let next_limit = consumed +
      stream.recv_window.min(QUIC_MAX_VARINT - consumed)
    if next_limit > stream.recv_max {
      self.pending_stream_credit[id] = next_limit
    }
  }
  Ok(())
}

///|
/// Limit a batch to one packet. Only the frames actually handed to recovery
/// are committed, so congestion or partial batches cannot lose updates.
fn QuicConnection::credit_updates(
  self : QuicConnection,
  budget : Int32,
) -> Array[QuicFrame] {
  if self.released_receive_bytes == 0L &&
    self.incoming_bidi.retired_credit == 0L &&
    self.incoming_uni.retired_credit == 0L &&
    self.pending_stream_credit.is_empty() {
    return []
  }
  let frames : Array[QuicFrame] = []
  let mut remaining = budget
  let append = fn(frame : QuicFrame, size : Int32) {
    if size > remaining {
      return false
    }
    frames.push(frame)
    remaining -= size
    true
  }
  if self.released_receive_bytes > 0L {
    let limit = self.local_max_data + self.released_receive_bytes
    ignore(append(MaxData(limit), 1 + quic_encoded_varint_size(limit)))
  }
  for
    (uni, incoming) in [(false, self.incoming_bidi), (true, self.incoming_uni)] {
    if incoming.retired_credit > 0L {
      let limit = incoming.advertised + incoming.retired_credit
      ignore(
        append(MaxStreams(uni, limit), 1 + quic_encoded_varint_size(limit)),
      )
    }
  }
  for id, value in self.pending_stream_credit {
    let size = 1 +
      quic_encoded_varint_size(id) +
      quic_encoded_varint_size(value)
    if !append(MaxStreamData(id, value), size) {
      break
    }
  }
  frames
}

///|
fn QuicConnection::commit_credit_updates(
  self : QuicConnection,
  frames : Array[QuicFrame],
) -> Unit {
  for frame in frames {
    match frame {
      MaxData(value) => {
        self.released_receive_bytes -= value - self.local_max_data
        self.local_max_data = value
      }
      MaxStreams(uni, value) => {
        let incoming = if uni { self.incoming_uni } else { self.incoming_bidi }
        incoming.retired_credit -= value - incoming.advertised
        incoming.advertised = value
      }
      MaxStreamData(id, value) => {
        if self.streams.get(id) is Some(stream) {
          stream.recv_max = value
        }
        self.pending_stream_credit.remove(id)
      }
      _ => ()
    }
  }
}

///|
/// Takes coalesced receive-credit updates for reliable transmission by a custom
/// transport. The built-in datagram driver handles these updates in poll().
pub fn QuicConnection::take_credit_updates(
  self : QuicConnection,
) -> Array[QuicFrame] {
  let frames = self.credit_updates(@int.MAX_VALUE)
  self.commit_credit_updates(frames)
  frames
}
