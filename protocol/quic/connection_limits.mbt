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
  self.peer_max_data = params.initial_max_data.min(
    self.limits.max_connection_data,
  )
  self.peer_max_streams_bidi = params.initial_max_streams_bidi
  self.peer_max_streams_uni = params.initial_max_streams_uni
  Ok(())
}

///|
pub fn QuicConnection::open_unidirectional_stream(
  self : QuicConnection,
) -> Result[Int64, QuicError] {
  if self.state != Established {
    return Err(
      Unsupported("application streams require an established connection"),
    )
  }
  if self.streams.length() >= self.limits.max_streams ||
    self.next_uni_stream_id >> 2 >= self.peer_max_streams_uni {
    return Err(FlowControl(0L, "maximum unidirectional stream count reached"))
  }
  let id = self.next_uni_stream_id
  if id > QUIC_MAX_VARINT - 4L {
    return Err(VarIntOverflow)
  }
  let stream = match
    quic_new_stream_state(
      self.peer_transport_params.unwrap().initial_max_stream_data_uni.min(
        self.limits.max_stream_data,
      ),
      0L,
      0,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  self.streams.set(id, stream)
  self.next_uni_stream_id += 4L
  Ok(id)
}

///|
pub fn QuicConnection::close_reason(self : QuicConnection) -> (Int64, String)? {
  self.close_error
}
