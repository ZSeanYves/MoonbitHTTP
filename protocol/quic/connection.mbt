///|
pub(all) enum QuicConnectionState {
  Handshaking
  Established
  Draining
  Closed
} derive(Eq, Debug)

///|
priv struct QuicStreamState {
  mut send_max : Int64
  mut recv_max : Int64
  recv_window : Int64
  outstanding : SentStreamRanges
  mut send_offset : Int64
  mut recv_offset : Int64
  mut fin_sent : Bool
  mut fin_received : Bool
  mut recv_final_size : Int64?
  reassembler : QuicCryptoReassembler
  mut reset : Bool
}

///|
fn quic_new_stream_state(
  send_max : Int64,
  recv_max : Int64,
  reassembly_limit : Int,
) -> Result[QuicStreamState, QuicError] {
  let reassembler = match
    QuicCryptoReassembler::new(max_bytes=reassembly_limit) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    send_max,
    recv_max,
    recv_window: recv_max,
    outstanding: { ranges: [], bytes: 0L, },
    send_offset: 0L,
    recv_offset: 0L,
    fin_sent: false,
    fin_received: false,
    recv_final_size: None,
    reassembler,
    reset: false,
  })
}

///|
pub(all) enum QuicAction {
  SendFrame(QuicFrame)
  StreamData(Int64, Bytes, Bool)
  StreamReset(Int64, Int64)
  ConnectionError(Int64, String)
  PeerAck(AckFrame)
  PacketIgnored
} derive(Eq, Debug)

///|
pub struct QuicConnection {
  priv role : QuicRole
  priv mut state : QuicConnectionState
  priv limits : QuicLimits
  priv transport_params : QuicTransportParams
  priv mut peer_transport_params : QuicTransportParams?
  priv streams : Map[Int64, QuicStreamState]
  priv mut connection_send_offset : Int64
  priv mut connection_recv_offset : Int64
  priv mut peer_max_data : Int64
  priv mut local_max_data : Int64
  priv pending_stream_credit : Map[Int64, Int64]
  priv mut released_receive_bytes : Int64
  priv mut retained_send_bytes : Int64
  priv incoming_bidi : IncomingStreams
  priv incoming_uni : IncomingStreams
  priv recent_final_sizes : Map[Int64, Int64]
  priv final_size_ids : Array[Int64]
  priv mut final_size_cursor : Int
  priv mut peer_max_streams_bidi : Int64
  priv mut peer_max_streams_uni : Int64
  priv mut next_stream_id : Int64
  priv mut next_uni_stream_id : Int64
  priv mut close_error : (Int64, String)?
}

///|
pub fn QuicConnection::new(
  role : QuicRole,
  limits? : QuicLimits = QuicLimits::defaults(),
  transport_params? : QuicTransportParams = QuicTransportParams::defaults(),
) -> Result[QuicConnection, QuicError] {
  match limits.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match transport_params.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let transport_params = {
    ..transport_params,
    initial_max_data: transport_params.initial_max_data.min(
      limits.max_connection_data,
    ),
    initial_max_stream_data_uni: transport_params.initial_max_stream_data_uni.min(
      limits.max_stream_data,
    ),
    initial_max_stream_data_bidi_local: transport_params.initial_max_stream_data_bidi_local.min(
      limits.max_stream_data,
    ),
    initial_max_stream_data_bidi_remote: transport_params.initial_max_stream_data_bidi_remote.min(
      limits.max_stream_data,
    ),
  }
  let first_stream = if role == Client { 0L } else { 1L }
  Ok({
    role,
    state: Handshaking,
    limits,
    transport_params,
    peer_transport_params: None,
    streams: Map([]),
    connection_send_offset: 0L,
    pending_stream_credit: Map([]),
    released_receive_bytes: 0L,
    retained_send_bytes: 0L,
    incoming_bidi: IncomingStreams::new(
      first_stream ^ 1L,
      transport_params.initial_max_streams_bidi,
    ),
    incoming_uni: IncomingStreams::new(
      (first_stream ^ 1L) + 2L,
      transport_params.initial_max_streams_uni,
    ),
    recent_final_sizes: Map([]),
    final_size_ids: [],
    final_size_cursor: 0,
    connection_recv_offset: 0L,
    peer_max_data: 0L,
    local_max_data: transport_params.initial_max_data,
    next_stream_id: first_stream,
    next_uni_stream_id: first_stream + 2L,
    peer_max_streams_bidi: 0L,
    peer_max_streams_uni: 0L,
    close_error: None,
  })
}

///|
pub fn QuicConnection::state(self : QuicConnection) -> QuicConnectionState {
  self.state
}

///|
pub fn QuicConnection::establish(
  self : QuicConnection,
) -> Result[Unit, QuicError] {
  if self.state == Closed || self.state == Draining {
    return Err(ConnectionClosed(0L, "connection is closing"))
  }
  if self.peer_transport_params is None {
    return Err(
      Unsupported("authenticated peer transport parameters are required"),
    )
  }
  self.state = Established
  Ok(())
}

///|
pub fn QuicConnection::receive_frame(
  self : QuicConnection,
  frame : QuicFrame,
) -> Result[Array[QuicAction], QuicError] {
  if self.state == Closed {
    return Err(ConnectionClosed(0L, "connection is closed"))
  }
  if self.state != Established {
    match frame {
      Padding(_) | Ping | Ack(_) | Crypto(_, _) | ConnectionClose(_, _, _, _) =>
        ()
      _ =>
        return Err(
          Unsupported("application frames require an established connection"),
        )
    }
  }
  let actions : Array[QuicAction] = []
  match frame {
    Ack(ack) => actions.push(PeerAck(ack))
    Stream(stream_frame) => {
      let id = stream_frame.stream_id
      let length = stream_frame.data.length().to_int64()
      if stream_frame.offset > QUIC_MAX_VARINT - length {
        return Err(VarIntOverflow)
      }
      let end = stream_frame.offset + length
      if self.is_retired(id) {
        return self.check_retired_range(id, end, stream_frame.fin)
      }
      let stream = match self.receive_stream(id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      match stream.recv_final_size {
        Some(final_size) if stream_frame.fin && end != final_size =>
          return Err(Protocol(0x6L, "final stream size changed"))
        Some(final_size) if end > final_size =>
          return Err(Protocol(0x6L, "data exceeds final stream size"))
        _ => ()
      }
      if stream_frame.fin && end < stream.recv_offset {
        return Err(Protocol(0x6L, "final size precedes received data"))
      }
      if end > stream.recv_max {
        return Err(FlowControl(id, "stream receive window exceeded"))
      }
      // RFC 9000 §4.1: gaps consume credit too. Duplicate and reordered
      // frames below the highest offset consume no additional credit.
      let new_bytes = (end - stream.recv_offset).max(0L)
      if new_bytes > self.local_max_data - self.connection_recv_offset {
        return Err(FlowControl(0L, "connection receive window exceeded"))
      }
      if stream.reset {
        return Ok(actions)
      }
      let chunks = match
        stream.reassembler.feed_bounded(
          stream_frame.offset,
          stream_frame.data,
          "STREAM reassembly",
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      stream.recv_offset = end.max(stream.recv_offset)
      if stream_frame.fin {
        stream.recv_final_size = Some(end)
        self.pending_stream_credit.remove(id)
      }
      self.connection_recv_offset += new_bytes
      let complete = stream.recv_final_size ==
        Some(stream.reassembler.next_offset())
      for index, chunk in chunks {
        let fin = complete && index == chunks.length() - 1
        actions.push(StreamData(id, chunk, fin))
      }
      if complete && !stream.fin_received {
        stream.fin_received = true
        if chunks.is_empty() {
          actions.push(StreamData(id, b"", true))
        }
      }
      self.retire_if_finished(id, stream)
    }
    MaxData(value) => {
      if value < 0L || value > QUIC_MAX_VARINT {
        return Err(InvalidFrame("invalid MAX_DATA limit"))
      }
      self.peer_max_data = self.peer_max_data.max(value)
    }
    MaxStreamData(id, value) => {
      if value < 0L || value > QUIC_MAX_VARINT {
        return Err(InvalidFrame("invalid MAX_STREAM_DATA limit"))
      }
      if (id & 2L) != 0L && !self.locally_initiated(id) {
        return Err(Protocol(0x5L, "MAX_STREAM_DATA for a receive-only stream"))
      }
      if self.is_retired(id) {
        return Ok(actions)
      }
      let stream = match self.streams.get(id) {
        Some(stream) => stream
        None =>
          match self.receive_stream(id) {
            Ok(stream) => stream
            Err(error) => return Err(error)
          }
      }
      stream.send_max = stream.send_max.max(value)
    }
    MaxStreams(uni, value) => {
      if value > 0x1000000000000000L || value < 0L {
        return Err(Protocol(0x7L, "MAX_STREAMS exceeds 2^60"))
      }
      if uni {
        self.peer_max_streams_uni = value.max(self.peer_max_streams_uni)
      } else {
        self.peer_max_streams_bidi = value.max(self.peer_max_streams_bidi)
      }
    }
    ResetStream(id, code, final_size) => {
      if self.is_retired(id) {
        return self.check_retired_range(id, final_size, true)
      }
      let stream = match self.receive_stream(id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if final_size < stream.recv_offset {
        return Err(
          Protocol(0x6L, "RESET_STREAM final size precedes received data"),
        )
      }
      if final_size > stream.recv_max {
        return Err(FlowControl(id, "RESET_STREAM exceeds receive window"))
      }
      match stream.recv_final_size {
        Some(previous) if previous != final_size =>
          return Err(Protocol(0x6L, "RESET_STREAM final size changed"))
        _ => ()
      }
      let new_bytes = final_size - stream.recv_offset
      if new_bytes > self.local_max_data - self.connection_recv_offset {
        return Err(
          FlowControl(0L, "RESET_STREAM exceeds connection receive window"),
        )
      }
      if stream.reset {
        return Ok(actions)
      }
      self.pending_stream_credit.remove(id)
      self.release_receive_credit(
        final_size - stream.reassembler.history_start(),
      )
      stream.reassembler.discard(final_size)
      stream.recv_final_size = Some(final_size)
      stream.recv_offset = final_size
      self.connection_recv_offset += new_bytes
      stream.reset = true
      actions.push(StreamReset(id, code))
      self.retire_if_finished(id, stream)
    }
    ConnectionClose(_, code, _, reason) => {
      self.state = Draining
      let text = @utf8.decode_lossy(reason)
      self.close_error = Some((code, text))
      actions.push(ConnectionError(code, text))
    }
    _ => ()
  }
  Ok(actions)
}
