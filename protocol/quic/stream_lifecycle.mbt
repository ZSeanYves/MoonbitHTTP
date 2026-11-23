///|
priv struct IncomingStreams {
  mut next_id : Int64
  implicit : Set[Int64]
  mut advertised : Int64
  mut retired_credit : Int64
}

///|
fn IncomingStreams::new(first : Int64, limit : Int64) -> IncomingStreams {
  { next_id: first, implicit: Set([]), advertised: limit, retired_credit: 0L, }
}

///|
fn QuicConnection::stream_slots_used(self : QuicConnection) -> Int {
  self.streams.length() +
  self.incoming_bidi.implicit.length() +
  self.incoming_uni.implicit.length()
}

///|
/// Below the per-type opening frontier, only live and implicitly opened streams
/// can still deliver data. This identifies arbitrarily old replayed frames
/// without retaining one entry per completed request.
fn QuicConnection::is_retired(self : QuicConnection, id : Int64) -> Bool {
  if id < 0L || self.streams.contains(id) {
    return false
  }
  let uni = (id & 2L) != 0L
  if self.locally_initiated(id) {
    id < (if uni { self.next_uni_stream_id } else { self.next_stream_id })
  } else {
    let incoming = if uni { self.incoming_uni } else { self.incoming_bidi }
    id < incoming.next_id && !incoming.implicit.contains(id)
  }
}

///|
fn QuicConnection::check_retired_range(
  self : QuicConnection,
  id : Int64,
  end : Int64,
  final_size : Bool,
) -> Result[Array[QuicAction], QuicError] {
  if (id & 2L) != 0L && self.locally_initiated(id) {
    return Err(Protocol(0x5L, "invalid receive stream direction"))
  }
  if self.recent_final_sizes.get(id) is Some(size) &&
    (end > size || (final_size && end != size)) {
    return Err(Protocol(0x6L, "inconsistent final size on retired stream"))
  }
  Ok([])
}

///|
/// Packet recovery owns retransmissions after the application hands off FIN.
/// Release application stream storage once both directions have finished.
fn QuicConnection::retire_if_finished(
  self : QuicConnection,
  id : Int64,
  stream : QuicStreamState,
) -> Unit {
  let uni = (id & 2L) != 0L
  let initiated_here = self.locally_initiated(id)
  let send_done = stream.fin_sent || (uni && !initiated_here)
  let receive_done = stream.fin_received ||
    stream.reset ||
    (uni && initiated_here)
  if !send_done || !receive_done {
    return
  }
  self.streams.remove(id)
  self.retained_send_bytes -= stream.outstanding.bytes
  self.release_receive_credit(
    stream.recv_offset - stream.reassembler.history_start(),
  )
  if !initiated_here {
    let incoming = if uni { self.incoming_uni } else { self.incoming_bidi }
    if incoming.advertised + incoming.retired_credit < 0x1000000000000000L {
      incoming.retired_credit += 1L
    }
  }
  if stream.recv_final_size is Some(size) {
    let capacity = self.limits.max_streams.min(256)
    if self.final_size_ids.length() < capacity {
      self.final_size_ids.push(id)
    } else {
      self.recent_final_sizes.remove(
        self.final_size_ids[self.final_size_cursor],
      )
      self.final_size_ids[self.final_size_cursor] = id
      self.final_size_cursor = (self.final_size_cursor + 1) % capacity
    }
    self.recent_final_sizes[id] = size
  }
}
