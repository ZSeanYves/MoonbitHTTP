///|
pub struct H2Connection {
  priv role : H2Role
  priv limits : @types.Limits
  priv local_settings : H2Settings
  priv pending_local_initial_windows : Array[Int32]
  priv peer_settings : H2Settings
  priv streams : Map[Int32, H2Stream]
  priv closed_streams : Array[Int32]
  priv mut connection_send_window : Int32
  priv mut connection_recv_window : Int32
  priv mut discarded_recv_bytes : Int32
  priv mut highest_remote_stream : Int32
  priv mut next_local_stream : Int32
  priv mut continuation_stream : Int32?
  priv mut continuation_bytes : Int32
  priv mut goaway_received : Bool
  priv mut goaway_last_stream : Int32?
  priv mut failure : H2ProtocolError?
}

///|
pub fn H2Connection::new(
  role : H2Role,
  limits~ : @types.Limits = @types.Limits::defaults(),
) -> H2Connection {
  {
    role,
    limits,
    local_settings: H2Settings::new(
      limits.max_streams.min(limits.max_concurrent_requests),
    ),
    pending_local_initial_windows: [],
    // Before the peer advertises a limit, only our own stream budget applies.
    peer_settings: H2Settings::new(limits.max_streams),
    streams: Map([]),
    closed_streams: [],
    connection_send_window: 65535,
    connection_recv_window: 65535,
    discarded_recv_bytes: 0,
    highest_remote_stream: 0,
    next_local_stream: if role == Client {
      1
    } else {
      2
    },
    continuation_stream: None,
    continuation_bytes: 0,
    goaway_received: false,
    goaway_last_stream: None,
    failure: None,
  }
}

///|
fn u31(payload : Array[Byte], offset : Int32) -> Int32 {
  ((payload[offset].to_int() & 0x7f) << 24) |
  ((payload[offset + 1].to_int() & 0xff) << 16) |
  ((payload[offset + 2].to_int() & 0xff) << 8) |
  (payload[offset + 3].to_int() & 0xff)
}

///|
fn u32(payload : Array[Byte], offset : Int32) -> Int32 {
  ((payload[offset].to_int() & 0xff) << 24) |
  ((payload[offset + 1].to_int() & 0xff) << 16) |
  ((payload[offset + 2].to_int() & 0xff) << 8) |
  (payload[offset + 3].to_int() & 0xff)
}

///|
fn H2Connection::receive_control_frame(
  self : H2Connection,
  frame : H2Frame,
) -> Result[Array[H2Action], H2ProtocolError] {
  let h = frame.header
  let actions : Array[H2Action] = []
  if h.stream_id != 0 {
    return Err(
      ConnectionError(
        ProtocolError,
        "connection control frame must use stream zero",
      ),
    )
  }
  match h.typ {
    H2_FRAME_SETTINGS => {
      if ((h.flags & H2_FLAGS_ACK) != 0 && !frame.payload.is_empty()) ||
        frame.payload.length() % 6 != 0 {
        return Err(
          ConnectionError(FrameSizeError, "invalid SETTINGS frame length"),
        )
      }
      if (h.flags & H2_FLAGS_ACK) == 0 {
        match self.apply_settings_entries(frame.payload) {
          Ok(updates) =>
            for update in updates {
              actions.push(update)
            }
          Err(error) => return Err(error)
        }
        actions.push(SendSettingsAck)
      } else {
        match self.acknowledge_local_initial_window() {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
      }
    }
    H2_FRAME_PING => {
      if frame.payload.length() != 8 {
        return Err(ConnectionError(FrameSizeError, "invalid PING frame"))
      }
      if (h.flags & H2_FLAGS_ACK) == 0 {
        actions.push(SendPingAck(frame.payload))
      }
    }
    H2_FRAME_GOAWAY => {
      if frame.payload.length() < 8 {
        return Err(ConnectionError(FrameSizeError, "invalid GOAWAY frame"))
      }
      let last_stream = u31(frame.payload, 0)
      match self.goaway_last_stream {
        Some(previous) if last_stream > previous =>
          return Err(
            ConnectionError(ProtocolError, "GOAWAY last stream id increased"),
          )
        _ => ()
      }
      self.goaway_received = true
      self.goaway_last_stream = Some(last_stream)
      actions.push(GoawayReceived(last_stream, u32(frame.payload, 4)))
    }
    _ => ()
  }
  Ok(actions)
}

///|
fn H2Connection::receive_impl(
  self : H2Connection,
  frame : H2Frame,
) -> Result[Array[H2Action], H2ProtocolError] {
  let h = frame.header
  if h.length != frame.payload.length() ||
    h.length < 0 ||
    h.length > self.local_settings.max_frame_size {
    return Err(ConnectionError(FrameSizeError, "invalid frame payload length"))
  }
  if h.typ < 0 ||
    h.typ > 0xff ||
    h.flags < 0 ||
    h.flags > 0xff ||
    h.stream_id < 0 ||
    h.stream_id > H2_MAX_WINDOW {
    return Err(ConnectionError(ProtocolError, "invalid HTTP/2 frame header"))
  }

  if self.continuation_stream is Some(expected) &&
    (h.typ != H2_FRAME_CONTINUATION || h.stream_id != expected) {
    return Err(
      ConnectionError(
        ProtocolError,
        "interleaved frame during header continuation",
      ),
    )
  }
  if h.typ == H2_FRAME_DATA && (h.flags & H2_FLAGS_PADDED) != 0 {
    if frame.payload.is_empty() {
      return Err(ConnectionError(FrameSizeError, "missing DATA pad length"))
    }
    if frame.payload[0].to_int() >= frame.payload.length() {
      return Err(ConnectionError(ProtocolError, "invalid DATA padding"))
    }
  }
  let header_fragment_length = if h.typ == H2_FRAME_HEADERS {
    match h2_header_fragment_bounds(frame) {
      Ok((start, end)) => end - start
      Err(error) => return Err(error)
    }
  } else {
    0
  }
  match h.typ {
    H2_FRAME_SETTINGS | H2_FRAME_PING | H2_FRAME_GOAWAY =>
      self.receive_control_frame(frame)
    H2_FRAME_WINDOW_UPDATE => self.receive_window_update(frame)
    H2_FRAME_HEADERS
    | H2_FRAME_CONTINUATION
    | H2_FRAME_DATA
    | H2_FRAME_RST_STREAM
    | H2_FRAME_PRIORITY
    | H2_FRAME_PUSH_PROMISE =>
      self.receive_stream_frame(frame, header_fragment_length)
    _ => Ok([])
  }
}

///|
pub fn H2Connection::receive(
  self : H2Connection,
  frame : H2Frame,
) -> Result[Array[H2Action], H2ProtocolError] {
  if self.failure is Some(error) {
    return Err(error)
  }
  match self.receive_impl(frame) {
    Err(error) => {
      match error {
        ConnectionError(_, _) => self.failure = Some(error)
        StreamError(stream_id, code, _) => {
          // Recoverable DATA errors still consume connection credit, including
          // in-flight frames on reset streams. Keep their discard accounting
          // separate from application-owned DATA until the driver releases it.
          if frame.header.typ == H2_FRAME_DATA {
            self.discarded_recv_bytes += frame.header.length
          }
          if self.streams.get(stream_id) is Some(stream) {
            stream.state = Closed
            self.remove_closed_stream(stream_id)
          }
          if frame.header.typ == H2_FRAME_HEADERS {
            // Stream rejection does not end the connection's compression
            // context. Keep bounded continuation state and ask the consumer to
            // decode this block without delivering any application fields.
            let fragment = match header_fragment(frame) {
              Ok(value) => value
              Err(error) => {
                self.failure = Some(error)
                return Err(error)
              }
            }
            if fragment.length() > self.limits.max_header_bytes {
              let error = ConnectionError(
                EnhanceYourCalm,
                "HTTP/2 header block exceeds configured limit",
              )
              self.failure = Some(error)
              return Err(error)
            }
            let end_headers = (frame.header.flags & H2_FLAGS_END_HEADERS) != 0
            self.continuation_bytes = if end_headers {
              0
            } else {
              fragment.length()
            }
            if !end_headers {
              self.continuation_stream = Some(stream_id)
            }
            return Ok([HeadersDiscarded(stream_id, end_headers, code)])
          }
        }
      }
      Err(error)
    }
    value => value
  }
}
