///|
pub(all) enum H2StreamState {
  Idle
  Open
  HalfClosedLocal
  HalfClosedRemote
  Closed
} derive(Debug, Eq)

///|
/// Closed stream IDs are retained only long enough to preserve precise
/// post-close errors; flow-control records themselves are reclaimed.
const H2_CLOSED_STREAM_HISTORY : Int = 1024

///|
priv struct H2Stream {
  id : Int
  mut state : H2StreamState
  mut send_window : Int
  mut recv_window : Int
}

///|
fn H2Connection::is_remote_stream_id(self : H2Connection, id : Int) -> Bool {
  if self.role == Client {
    id % 2 == 0
  } else {
    id % 2 == 1
  }
}

///|
fn close_remote_side(stream : H2Stream) -> Unit {
  stream.state = match stream.state {
    Open => HalfClosedRemote
    HalfClosedLocal => Closed
    state => state
  }
}

///|
fn close_local_side(stream : H2Stream) -> Unit {
  stream.state = match stream.state {
    Open => HalfClosedLocal
    HalfClosedRemote => Closed
    state => state
  }
}

///|
/// Closed stream records no longer carry flow-control state. The stream ID
/// monotonicity fields below retain enough history to distinguish an already
/// created stream from an idle future stream after its record is reclaimed.
fn H2Connection::was_created_stream_id(self : H2Connection, id : Int) -> Bool {
  if id < 0 {
    false
  } else if self.is_remote_stream_id(id) {
    id <= self.highest_remote_stream
  } else {
    self.next_local_stream == -1 || id < self.next_local_stream
  }
}

///|
fn H2Connection::remember_closed_stream(self : H2Connection, id : Int) -> Unit {
  if self.closed_streams.contains(id) {
    return
  }
  self.closed_streams.push(id)
  if self.closed_streams.length() > H2_CLOSED_STREAM_HISTORY {
    self.closed_streams.remove(0) |> ignore
  }
}

///|
fn H2Connection::remove_closed_stream(self : H2Connection, id : Int) -> Unit {
  match self.streams.get(id) {
    Some(stream) if stream.state == Closed => {
      self.streams.remove(id)
      self.remember_closed_stream(id)
    }
    _ => ()
  }
}

///|
pub fn H2Connection::open_local_stream(
  self : H2Connection,
  end_stream? : Bool = false,
) -> Result[Int, H2ProtocolError] {
  if self.failure is Some(error) {
    return Err(error)
  }
  if self.goaway_received {
    return Err(
      ConnectionError(ProtocolError, "cannot open a stream after GOAWAY"),
    )
  }
  let mut active = 0
  for stream in self.streams.values() {
    if !self.is_remote_stream_id(stream.id) && stream.state != Closed {
      active += 1
    }
  }
  if active >= self.peer_settings.max_concurrent_streams ||
    active >= self.limits.max_streams {
    return Err(
      ConnectionError(RefusedStream, "peer concurrent stream limit reached"),
    )
  }
  if self.next_local_stream <= 0 || self.next_local_stream > 0x7fffffff {
    return Err(
      ConnectionError(RefusedStream, "local stream identifiers are exhausted"),
    )
  }
  let id = self.next_local_stream
  self.next_local_stream = if id > 0x7fffffff - 2 { -1 } else { id + 2 }
  let stream : H2Stream = {
    id,
    state: if end_stream {
      HalfClosedLocal
    } else {
      Open
    },
    send_window: self.peer_settings.initial_window_size,
    recv_window: self.local_settings.initial_window_size,
  }
  self.streams.set(id, stream)
  Ok(id)
}

///|
/// Maps an h2c upgrade request to a remotely closed HTTP/2 stream 1.
pub fn H2Connection::accept_upgraded_stream1(
  self : H2Connection,
) -> Result[Unit, H2ProtocolError] {
  if self.role != Server || self.highest_remote_stream != 0 {
    return Err(
      ConnectionError(ProtocolError, "invalid h2c stream 1 transition"),
    )
  }
  self.highest_remote_stream = 1
  self.streams.set(1, {
    id: 1,
    state: HalfClosedRemote,
    send_window: self.peer_settings.initial_window_size,
    recv_window: self.local_settings.initial_window_size,
  })
  Ok(())
}

///|
fn H2Connection::get_open_stream(
  self : H2Connection,
  id : Int,
) -> Result[H2Stream, H2ProtocolError] {
  match self.streams.get(id) {
    None =>
      Err(
        StreamError(
          id,
          StreamClosed,
          if self.was_created_stream_id(id) {
            "frame references a closed stream"
          } else {
            "frame references an idle stream"
          },
        ),
      )
    Some(stream) if stream.state == Closed || stream.state == HalfClosedRemote =>
      Err(StreamError(id, StreamClosed, "frame received after remote end"))
    Some(stream) => Ok(stream)
  }
}

///|
fn H2Connection::receive_stream_frame(
  self : H2Connection,
  frame : H2Frame,
  header_fragment_length : Int,
) -> Result[Array[H2Action], H2ProtocolError] {
  let h = frame.header
  let actions : Array[H2Action] = []
  match h.typ {
    H2_FRAME_HEADERS => {
      if h.stream_id == 0 {
        return Err(ConnectionError(ProtocolError, "HEADERS requires a stream"))
      }
      let stream = match self.streams.get(h.stream_id) {
        Some(value) => value
        None => {
          let mut active = 0
          for stream in self.streams.values() {
            if self.is_remote_stream_id(stream.id) && stream.state != Closed {
              active += 1
            }
          }
          if active >= self.local_settings.max_concurrent_streams ||
            active >= self.limits.max_streams {
            return Err(
              StreamError(
                h.stream_id,
                RefusedStream,
                "local concurrent stream limit reached",
              ),
            )
          }
          if !self.is_remote_stream_id(h.stream_id) ||
            h.stream_id <= self.highest_remote_stream {
            if self.closed_streams.contains(h.stream_id) {
              return Err(
                StreamError(
                  h.stream_id,
                  StreamClosed,
                  "HEADERS on closed stream",
                ),
              )
            }
            return Err(
              ConnectionError(ProtocolError, "invalid new remote stream id"),
            )
          }
          if self.goaway_last_stream is Some(last) && h.stream_id > last {
            return Err(
              ConnectionError(
                ProtocolError,
                "new stream was opened after GOAWAY",
              ),
            )
          }
          self.highest_remote_stream = h.stream_id
          let value : H2Stream = {
            id: h.stream_id,
            state: Open,
            send_window: self.peer_settings.initial_window_size,
            recv_window: self.local_settings.initial_window_size,
          }
          self.streams.set(h.stream_id, value)
          value
        }
      }
      if stream.state == Closed || stream.state == HalfClosedRemote {
        return Err(
          StreamError(h.stream_id, StreamClosed, "HEADERS on closed stream"),
        )
      }
      let end_stream = (h.flags & H2_FLAGS_END_STREAM) != 0
      if end_stream {
        close_remote_side(stream)
        self.remove_closed_stream(h.stream_id)
      }
      let end_headers = (h.flags & H2_FLAGS_END_HEADERS) != 0
      if header_fragment_length > self.limits.max_header_bytes {
        return Err(
          ConnectionError(
            EnhanceYourCalm,
            "HTTP/2 header block exceeds configured limit",
          ),
        )
      }
      self.continuation_bytes = if end_headers {
        0
      } else {
        header_fragment_length
      }
      if !end_headers {
        self.continuation_stream = Some(h.stream_id)
      }
      actions.push(HeadersStarted(h.stream_id, end_stream))
    }
    H2_FRAME_CONTINUATION => {
      if self.continuation_stream != Some(h.stream_id) {
        return Err(ConnectionError(ProtocolError, "unexpected CONTINUATION"))
      }
      let end_headers = (h.flags & H2_FLAGS_END_HEADERS) != 0
      if h.length > self.limits.max_header_bytes - self.continuation_bytes {
        return Err(
          ConnectionError(
            EnhanceYourCalm,
            "HTTP/2 header block exceeds configured limit",
          ),
        )
      }
      self.continuation_bytes += h.length
      if end_headers {
        self.continuation_stream = None
        self.continuation_bytes = 0
      }
      actions.push(HeadersContinued(h.stream_id, end_headers))
    }
    H2_FRAME_DATA => {
      if h.stream_id == 0 {
        return Err(ConnectionError(ProtocolError, "DATA requires a stream"))
      }
      let stream = match self.get_open_stream(h.stream_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if h.length > self.connection_recv_window {
        return Err(
          ConnectionError(
            FlowControlError,
            "connection receive window exhausted",
          ),
        )
      }
      self.connection_recv_window -= h.length
      if h.length > 0 && h.length > stream.recv_window {
        return Err(
          StreamError(
            h.stream_id,
            FlowControlError,
            "stream receive window exhausted",
          ),
        )
      }
      stream.recv_window -= h.length
      let end_stream = (h.flags & H2_FLAGS_END_STREAM) != 0
      if end_stream {
        close_remote_side(stream)
        self.remove_closed_stream(h.stream_id)
      }
      let data = if (h.flags & H2_FLAGS_PADDED) != 0 {
        let padding = frame.payload[0].to_int()
        frame.payload[1:frame.payload.length() - padding].to_owned()
      } else {
        frame.payload
      }
      actions.push(DataReceived(h.stream_id, data, end_stream, h.length))
    }
    H2_FRAME_RST_STREAM => {
      if h.stream_id == 0 || frame.payload.length() != 4 {
        return Err(ConnectionError(FrameSizeError, "invalid RST_STREAM"))
      }
      let stream = match self.streams.get(h.stream_id) {
        Some(value) => value
        None =>
          return Err(
            if self.was_created_stream_id(h.stream_id) {
              StreamError(
                h.stream_id,
                StreamClosed,
                "RST_STREAM on closed stream",
              )
            } else {
              ConnectionError(ProtocolError, "RST_STREAM on idle stream")
            },
          )
      }
      stream.state = Closed
      self.remove_closed_stream(h.stream_id)
      actions.push(StreamResetReceived(h.stream_id, u32(frame.payload, 0)))
    }
    H2_FRAME_PRIORITY =>
      if h.stream_id == 0 || frame.payload.length() != 5 {
        return Err(ConnectionError(FrameSizeError, "invalid PRIORITY frame"))
      } else {
        let dependency = ((frame.payload[0].to_int() & 0x7f) << 24) |
          ((frame.payload[1].to_int() & 0xff) << 16) |
          ((frame.payload[2].to_int() & 0xff) << 8) |
          (frame.payload[3].to_int() & 0xff)
        if dependency == h.stream_id {
          return Err(
            ConnectionError(ProtocolError, "PRIORITY depends on itself"),
          )
        }
      }
    H2_FRAME_PUSH_PROMISE =>
      if h.stream_id == 0 ||
        self.role == Server ||
        !self.local_settings.enable_push {
        return Err(
          ConnectionError(ProtocolError, "PUSH_PROMISE is not permitted"),
        )
      } else {
        let mut offset = 0
        let mut padding = 0
        if (h.flags & H2_FLAGS_PADDED) != 0 {
          if frame.payload.is_empty() {
            return Err(ConnectionError(FrameSizeError, "invalid PUSH_PROMISE"))
          }
          padding = frame.payload[0].to_int()
          offset = 1
        }
        if offset + 4 + padding > frame.payload.length() {
          return Err(
            ConnectionError(FrameSizeError, "invalid PUSH_PROMISE padding"),
          )
        }
        let promised = ((frame.payload[offset].to_int() & 0x7f) << 24) |
          ((frame.payload[offset + 1].to_int() & 0xff) << 16) |
          ((frame.payload[offset + 2].to_int() & 0xff) << 8) |
          (frame.payload[offset + 3].to_int() & 0xff)
        if promised == 0 ||
          promised > H2_MAX_WINDOW ||
          !self.is_remote_stream_id(promised) {
          return Err(
            ConnectionError(ProtocolError, "invalid promised stream id"),
          )
        }
      }
    _ => ()
  }
  Ok(actions)
}

///|
pub fn H2Connection::finish_local_stream(
  self : H2Connection,
  stream_id : Int,
) -> Result[Unit, H2ProtocolError] {
  match self.streams.get(stream_id) {
    None => Err(StreamError(stream_id, StreamClosed, "unknown stream"))
    Some(stream) => {
      close_local_side(stream)
      self.remove_closed_stream(stream_id)
      Ok(())
    }
  }
}

///|
pub fn H2Connection::reset_stream(
  self : H2Connection,
  stream_id : Int,
) -> Result[Unit, H2ProtocolError] {
  match self.streams.get(stream_id) {
    None => Err(StreamError(stream_id, StreamClosed, "unknown stream"))
    Some(stream) => {
      stream.state = Closed
      self.remove_closed_stream(stream_id)
      Ok(())
    }
  }
}

///|
pub fn H2Connection::stream_state(
  self : H2Connection,
  stream_id : Int,
) -> H2StreamState? {
  match self.streams.get(stream_id) {
    Some(stream) => Some(stream.state)
    None if self.closed_streams.contains(stream_id) => Some(Closed)
    None => None
  }
}
