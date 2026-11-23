///|
fn QuicConnection::locally_initiated(self : QuicConnection, id : Int64) -> Bool {
  (id & 1L) == (if self.role == Client { 0L } else { 1L })
}

///|
/// The trusted handshake adapter calls this once, after authenticating the
/// peer transport-parameter extension. Local receive limits never grant send
/// credit. This method does not complete the handshake.
pub fn QuicConnection::set_peer_transport_params(
  self : QuicConnection,
  params : QuicTransportParams,
) -> Result[Unit, QuicError] {
  if self.state != Handshaking || self.peer_transport_params is Some(_) {
    return Err(
      InvalidTransportParameter(
        "peer parameters already installed or connection is not handshaking",
      ),
    )
  }
  match params.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  self.peer_transport_params = Some(params)
  self.peer_max_data = params.initial_max_data
  self.peer_max_streams_bidi = params.initial_max_streams_bidi
  self.peer_max_streams_uni = params.initial_max_streams_uni
  Ok(())
}

///|
fn QuicConnection::open_stream(
  self : QuicConnection,
  uni : Bool,
) -> Result[Int64, QuicError] {
  match self.state {
    Closed | Draining =>
      return Err(ConnectionClosed(0L, "connection is not accepting streams"))
    Handshaking =>
      return Err(
        Unsupported("application streams require an established connection"),
      )
    Established => ()
  }
  let (id, count) = if uni {
    (self.next_uni_stream_id, self.peer_max_streams_uni)
  } else {
    (self.next_stream_id, self.peer_max_streams_bidi)
  }
  if self.stream_slots_used() >= self.limits.max_streams || id >> 2 >= count {
    return Err(FlowControl(0L, "maximum stream count reached"))
  }
  // IDs advance in steps of four. The opening frontier may exceed the final
  // wire ID by four, which still fits in Int64.
  let peer = self.peer_transport_params.unwrap()
  let send_limit = if uni {
    peer.initial_max_stream_data_uni
  } else {
    peer.initial_max_stream_data_bidi_remote
  }
  let receive_limit = if uni {
    0L
  } else {
    self.transport_params.initial_max_stream_data_bidi_local
  }
  let stream = match
    quic_new_stream_state(
      send_limit,
      receive_limit,
      if uni {
        0
      } else {
        self.limits.max_stream_data.to_int()
      },
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  self.streams[id] = stream
  if uni {
    self.next_uni_stream_id += 4L
  } else {
    self.next_stream_id += 4L
  }
  Ok(id)
}

///|
pub fn QuicConnection::open_bidirectional_stream(
  self : QuicConnection,
) -> Result[Int64, QuicError] {
  self.open_stream(false)
}

///|
pub fn QuicConnection::open_unidirectional_stream(
  self : QuicConnection,
) -> Result[Int64, QuicError] {
  self.open_stream(true)
}

///|
pub fn QuicConnection::close_reason(self : QuicConnection) -> (Int64, String)? {
  self.peer_close.map(fn(close) {
    match close {
      TransportClose(code, reason) | ApplicationClose(code, reason) =>
        (code, reason)
    }
  })
}

///|
pub fn QuicConnection::peer_close(self : QuicConnection) -> QuicPeerClose? {
  self.peer_close
}

///|
/// Effective local transport parameters for a custom handshake adapter.
pub fn QuicConnection::local_transport_params(
  self : QuicConnection,
) -> QuicTransportParams {
  self.transport_params
}
