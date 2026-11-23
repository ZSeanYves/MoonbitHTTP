///|
/// STREAM and RESET_STREAM share the same direction, implicit-open and
/// stream-count rules. Keeping this gate in the state owner also permits a
/// reset to be the first frame observed for a peer-initiated stream.
fn QuicConnection::receive_stream(
  self : QuicConnection,
  id : Int64,
) -> Result[QuicStreamState, QuicError] {
  let initiated_here = self.locally_initiated(id)
  let uni = (id & 2L) != 0L
  if id < 0L || id > QUIC_MAX_VARINT || (uni && initiated_here) {
    return Err(Protocol(0x5L, "invalid receive stream direction"))
  }
  if self.streams.get(id) is Some(value) {
    return Ok(value)
  }
  if initiated_here {
    return Err(Protocol(0x5L, "peer used an unopened local stream"))
  }
  let incoming = if uni { self.incoming_uni } else { self.incoming_bidi }
  if id >> 2 >= incoming.advertised {
    return Err(Protocol(0x4L, "peer stream limit exceeded"))
  }
  let implied = if id >= incoming.next_id {
    (id - incoming.next_id) / 4L + 1L
  } else {
    0L
  }
  if implied > (self.limits.max_streams - self.stream_slots_used()).to_int64() {
    return Err(FlowControl(id, "maximum stream count reached"))
  }
  let peer = match self.peer_transport_params {
    Some(value) => value
    None => return Err(Unsupported("peer transport parameters are required"))
  }
  let value = match
    quic_new_stream_state(
      if uni {
        0L
      } else {
        peer.initial_max_stream_data_bidi_local.min(self.limits.max_stream_data)
      },
      (if uni {
        self.transport_params.initial_max_stream_data_uni
      } else {
        self.transport_params.initial_max_stream_data_bidi_remote
      }).min(self.limits.max_stream_data),
      self.limits.max_stream_data.to_int(),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if implied > 0L {
    while incoming.next_id < id {
      incoming.implicit.add(incoming.next_id)
      incoming.next_id += 4L
    }
    incoming.next_id = id + 4L
  } else if incoming.implicit.contains(id) {
    incoming.implicit.remove(id)
  } else {
    return Err(StreamClosed(id))
  }
  self.streams.set(id, value)
  Ok(value)
}
