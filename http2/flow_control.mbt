///|
/// Maximum positive HTTP/2 flow-control window.
const H2_MAX_WINDOW : Int = 0x7fffffff

///|
/// Minimum signed stream window after a SETTINGS decrease.
const H2_MIN_WINDOW : Int = -0x80000000

///|
/// Register the stream window carried by an outgoing SETTINGS frame, before
/// opening streams. The RFC default remains in effect until the peer's ACK:
/// DATA already in flight may legally use the old window. Each call must be
/// paired with one outgoing SETTINGS frame, in the same order.
pub fn H2Connection::set_local_initial_window(
  self : H2Connection,
  window : Int,
) -> Result[Unit, H2ProtocolError] {
  if window < 0 || window > 0x7fffffff {
    return Err(
      ConnectionError(
        FlowControlError,
        "initial receive window is outside the HTTP/2 range",
      ),
    )
  }
  if !self.streams.is_empty() {
    return Err(
      ConnectionError(
        ProtocolError,
        "initial receive window must be set before opening streams",
      ),
    )
  }
  self.pending_local_initial_windows.push(window)
  Ok(())
}

///|
fn H2Connection::acknowledge_local_initial_window(
  self : H2Connection,
) -> Result[Unit, H2ProtocolError] {
  if self.pending_local_initial_windows.is_empty() {
    return Ok(())
  }
  let window = self.pending_local_initial_windows[0]
  let delta = window - self.local_settings.initial_window_size
  for stream in self.streams.values() {
    if (delta > 0 && stream.recv_window > H2_MAX_WINDOW - delta) ||
      (delta < 0 && stream.recv_window < H2_MIN_WINDOW - delta) {
      return Err(
        ConnectionError(
          FlowControlError,
          "receive window overflow after SETTINGS acknowledgement",
        ),
      )
    }
  }
  for stream in self.streams.values() {
    // A decrease can make a window negative while prior DATA remains queued.
    // Consuming that DATA restores credit through normal WINDOW_UPDATEs.
    stream.recv_window += delta
  }
  self.local_settings.initial_window_size = window
  ignore(self.pending_local_initial_windows.remove(0))
  Ok(())
}

///|
/// Expands the local connection-level receive window. HTTP/2 SETTINGS only
/// changes stream windows, so callers must pair this with a connection
/// WINDOW_UPDATE frame sent to the peer.
pub fn H2Connection::increase_connection_receive_window(
  self : H2Connection,
  increment : Int,
) -> Result[Unit, H2ProtocolError] {
  if increment <= 0 || self.connection_recv_window > 0x7fffffff - increment {
    return Err(
      ConnectionError(
        FlowControlError,
        "invalid connection receive window increment",
      ),
    )
  }
  self.connection_recv_window += increment
  Ok(())
}

///|
fn H2Connection::receive_window_update(
  self : H2Connection,
  frame : H2Frame,
) -> Result[Array[H2Action], H2ProtocolError] {
  let h = frame.header
  let actions : Array[H2Action] = []
  match h.typ {
    H2_FRAME_WINDOW_UPDATE => {
      if frame.payload.length() != 4 {
        return Err(
          ConnectionError(FrameSizeError, "invalid WINDOW_UPDATE frame"),
        )
      }
      let increment = u31(frame.payload, 0)
      if increment == 0 {
        return Err(
          if h.stream_id == 0 {
            ConnectionError(ProtocolError, "zero connection window increment")
          } else {
            StreamError(
              h.stream_id,
              ProtocolError,
              "zero stream window increment",
            )
          },
        )
      }
      if h.stream_id == 0 {
        if self.connection_send_window > 0x7fffffff - increment {
          return Err(
            ConnectionError(FlowControlError, "connection window overflow"),
          )
        }
        self.connection_send_window += increment
      } else {
        let stream = match self.streams.get(h.stream_id) {
          Some(value) => value
          None =>
            return Err(
              StreamError(
                h.stream_id,
                StreamClosed,
                "WINDOW_UPDATE on idle stream",
              ),
            )
        }
        if stream.send_window > 0x7fffffff - increment {
          return Err(
            StreamError(h.stream_id, FlowControlError, "stream window overflow"),
          )
        }
        stream.send_window += increment
      }
      actions.push(WindowAvailable(h.stream_id, increment))
    }
    _ => ()
  }
  Ok(actions)
}

///|
pub fn H2Connection::release_capacity(
  self : H2Connection,
  stream_id : Int,
  amount : Int,
) -> Result[Array[H2Action], H2ProtocolError] {
  if amount <= 0 {
    return Err(
      ConnectionError(ProtocolError, "released capacity must be positive"),
    )
  }
  let stream = match self.streams.get(stream_id) {
    Some(value) => value
    None if self.was_created_stream_id(stream_id) => {
      // A closed stream record may already be reclaimed. Its stream-level
      // window no longer needs an update, but consumed bytes still restore
      // the connection-level receive window.
      if self.connection_recv_window > 0x7fffffff - amount {
        return Err(ConnectionError(FlowControlError, "receive window overflow"))
      }
      self.connection_recv_window += amount
      return Ok([SendWindowUpdate(0, amount)])
    }
    None =>
      return Err(
        StreamError(stream_id, StreamClosed, "capacity for unknown stream"),
      )
  }
  if self.connection_recv_window > 0x7fffffff - amount ||
    stream.recv_window > 0x7fffffff - amount {
    return Err(ConnectionError(FlowControlError, "receive window overflow"))
  }
  self.connection_recv_window += amount
  stream.recv_window += amount
  Ok([SendWindowUpdate(0, amount), SendWindowUpdate(stream_id, amount)])
}

///|
/// Releases only connection-level receive capacity after bytes for a reset or
/// otherwise discarded stream have been accounted for.
pub fn H2Connection::release_connection_capacity(
  self : H2Connection,
  amount : Int,
) -> Result[H2Action, H2ProtocolError] {
  if amount <= 0 || self.connection_recv_window > 0x7fffffff - amount {
    return Err(
      ConnectionError(FlowControlError, "connection receive window overflow"),
    )
  }
  self.connection_recv_window += amount
  Ok(SendWindowUpdate(0, amount))
}

///|
pub fn H2Connection::reserve_send_capacity(
  self : H2Connection,
  stream_id : Int,
  requested : Int,
) -> Result[Int, H2ProtocolError] {
  if requested < 0 {
    return Err(
      StreamError(stream_id, FlowControlError, "negative send capacity request"),
    )
  }
  let stream = match self.streams.get(stream_id) {
    Some(value) => value
    None =>
      return Err(StreamError(stream_id, StreamClosed, "send on unknown stream"))
  }
  if stream.state == HalfClosedLocal || stream.state == Closed {
    return Err(
      StreamError(stream_id, StreamClosed, "stream send side is closed"),
    )
  }
  let amount = requested
    .min(self.connection_send_window)
    .min(stream.send_window)
    .min(self.peer_settings.max_frame_size)
  if amount <= 0 {
    return Ok(0)
  }
  self.connection_send_window -= amount
  stream.send_window -= amount
  Ok(amount)
}
