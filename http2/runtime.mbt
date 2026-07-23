///|
pub(all) enum H2ErrorCode {
  NoError
  ProtocolError
  InternalError
  FlowControlError
  SettingsTimeout
  StreamClosed
  FrameSizeError
  RefusedStream
  Cancel
  CompressionError
  ConnectError
  EnhanceYourCalm
  InadequateSecurity
  Http11Required
} derive(Debug, Eq)

///|
pub(all) suberror H2ProtocolError {
  ConnectionError(H2ErrorCode, String)
  StreamError(Int, H2ErrorCode, String)
} derive(Debug, Eq)

///|
pub(all) enum H2Role {
  Client
  Server
} derive(Debug, Eq)

///|
pub(all) enum H2StreamState {
  Idle
  Open
  HalfClosedLocal
  HalfClosedRemote
  Closed
} derive(Debug, Eq)

///|
pub(all) struct H2Settings {
  mut header_table_size : Int
  mut enable_push : Bool
  mut max_concurrent_streams : Int
  mut initial_window_size : Int
  mut max_frame_size : Int
  mut max_header_list_size : Int
}

///|
pub fn H2Settings::defaults() -> H2Settings {
  {
    header_table_size: 4096,
    enable_push: true,
    max_concurrent_streams: 100,
    initial_window_size: 65535,
    max_frame_size: H2_DEFAULT_MAX_FRAME_SIZE,
    max_header_list_size: 64 * 1024,
  }
}

///|
pub(all) struct H2Stream {
  id : Int
  mut state : H2StreamState
  mut send_window : Int
  mut recv_window : Int
}

///|
pub(all) enum H2Action {
  SendSettingsAck
  SendPingAck(Array[Byte])
  HeadersStarted(Int, Bool)
  HeadersContinued(Int, Bool)
  DataReceived(Int, Array[Byte], Bool)
  StreamResetReceived(Int, Int)
  GoawayReceived(Int, Int)
  WindowAvailable(Int, Int)
  SendWindowUpdate(Int, Int)
}

///|
pub struct H2Connection {
  role : H2Role
  local_settings : H2Settings
  peer_settings : H2Settings
  streams : Map[Int, H2Stream]
  mut connection_send_window : Int
  mut connection_recv_window : Int
  mut highest_remote_stream : Int
  mut next_local_stream : Int
  mut continuation_stream : Int?
  mut goaway_received : Bool
}

///|
pub fn H2Connection::new(role : H2Role) -> H2Connection {
  {
    role,
    local_settings: H2Settings::defaults(),
    peer_settings: H2Settings::defaults(),
    streams: Map([]),
    connection_send_window: 65535,
    connection_recv_window: 65535,
    highest_remote_stream: 0,
    next_local_stream: if role == Client {
      1
    } else {
      2
    },
    continuation_stream: None,
    goaway_received: false,
  }
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
pub fn H2Connection::open_local_stream(
  self : H2Connection,
  end_stream? : Bool = false,
) -> Result[Int, H2ProtocolError] {
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
  if active >= self.peer_settings.max_concurrent_streams {
    return Err(
      ConnectionError(RefusedStream, "peer concurrent stream limit reached"),
    )
  }
  let id = self.next_local_stream
  self.next_local_stream += 2
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
pub fn H2Connection::apply_settings_payload(
  self : H2Connection,
  payload : BytesView,
) -> Result[Unit, H2ProtocolError] {
  if payload.length() % 6 != 0 {
    return Err(
      ConnectionError(
        FrameSizeError,
        "HTTP2-Settings payload is not a multiple of 6",
      ),
    )
  }
  let bytes = payload.to_owned().to_array()
  let mut offset = 0
  while offset < bytes.length() {
    let id = ((bytes[offset].to_int() & 0xff) << 8) |
      (bytes[offset + 1].to_int() & 0xff)
    let value = u32(bytes, offset + 2)
    match self.apply_setting(id, value) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    offset += 6
  }
  Ok(())
}

///|
fn u31(payload : Array[Byte], offset : Int) -> Int {
  ((payload[offset].to_int() & 0x7f) << 24) |
  ((payload[offset + 1].to_int() & 0xff) << 16) |
  ((payload[offset + 2].to_int() & 0xff) << 8) |
  (payload[offset + 3].to_int() & 0xff)
}

///|
fn u32(payload : Array[Byte], offset : Int) -> Int {
  ((payload[offset].to_int() & 0xff) << 24) |
  ((payload[offset + 1].to_int() & 0xff) << 16) |
  ((payload[offset + 2].to_int() & 0xff) << 8) |
  (payload[offset + 3].to_int() & 0xff)
}

///|
fn H2Connection::apply_setting(
  self : H2Connection,
  id : Int,
  value : Int,
) -> Result[Unit, H2ProtocolError] {
  match id {
    1 => self.peer_settings.header_table_size = value
    2 => {
      if self.role == Client {
        return Err(
          ConnectionError(
            ProtocolError,
            "server must not send SETTINGS_ENABLE_PUSH",
          ),
        )
      }
      if value != 0 && value != 1 {
        return Err(
          ConnectionError(ProtocolError, "SETTINGS_ENABLE_PUSH must be 0 or 1"),
        )
      }
      self.peer_settings.enable_push = value == 1
    }
    3 => self.peer_settings.max_concurrent_streams = value
    4 => {
      if value < 0 || value > 0x7fffffff {
        return Err(
          ConnectionError(FlowControlError, "invalid initial window size"),
        )
      }
      let delta = value - self.peer_settings.initial_window_size
      for stream in self.streams.values() {
        if stream.send_window + delta > 0x7fffffff {
          return Err(
            ConnectionError(
              FlowControlError,
              "stream window overflow after SETTINGS",
            ),
          )
        }
        stream.send_window += delta
      }
      self.peer_settings.initial_window_size = value
    }
    5 => {
      if value < 16384 || value > 16777215 {
        return Err(ConnectionError(ProtocolError, "invalid max frame size"))
      }
      self.peer_settings.max_frame_size = value
    }
    6 => self.peer_settings.max_header_list_size = value
    _ => ()
  }
  Ok(())
}

///|
fn H2Connection::get_open_stream(
  self : H2Connection,
  id : Int,
) -> Result[H2Stream, H2ProtocolError] {
  match self.streams.get(id) {
    None =>
      Err(StreamError(id, StreamClosed, "frame references an idle stream"))
    Some(stream) if stream.state == Closed || stream.state == HalfClosedRemote =>
      Err(StreamError(id, StreamClosed, "frame received after remote end"))
    Some(stream) => Ok(stream)
  }
}

///|
pub fn H2Connection::receive(
  self : H2Connection,
  frame : H2Frame,
) -> Result[Array[H2Action], H2ProtocolError] {
  let h = frame.header
  if h.length != frame.payload.length() ||
    h.length > self.local_settings.max_frame_size {
    return Err(ConnectionError(FrameSizeError, "invalid frame payload length"))
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
    if frame.payload.is_empty() ||
      frame.payload[0].to_int() >= frame.payload.length() {
      return Err(ConnectionError(FrameSizeError, "invalid DATA padding"))
    }
  }
  if h.typ == H2_FRAME_HEADERS {
    let mut offset = 0
    if (h.flags & H2_FLAGS_PADDED) != 0 {
      if frame.payload.is_empty() {
        return Err(ConnectionError(FrameSizeError, "invalid HEADERS padding"))
      }
      let padding = frame.payload[0].to_int()
      offset = 1
      if padding + offset > frame.payload.length() {
        return Err(ConnectionError(FrameSizeError, "invalid HEADERS padding"))
      }
    }
    if (h.flags & H2_FLAGS_PRIORITY) != 0 {
      if offset + 5 > frame.payload.length() {
        return Err(ConnectionError(FrameSizeError, "invalid HEADERS priority"))
      }
      let dependency = ((frame.payload[offset].to_int() & 0x7f) << 24) |
        ((frame.payload[offset + 1].to_int() & 0xff) << 16) |
        ((frame.payload[offset + 2].to_int() & 0xff) << 8) |
        (frame.payload[offset + 3].to_int() & 0xff)
      if dependency == h.stream_id {
        return Err(ConnectionError(ProtocolError, "HEADERS depends on itself"))
      }
    }
  }
  let actions : Array[H2Action] = []
  match h.typ {
    H2_FRAME_SETTINGS => {
      if h.stream_id != 0 ||
        ((h.flags & H2_FLAGS_ACK) != 0 && !frame.payload.is_empty()) ||
        frame.payload.length() % 6 != 0 {
        return Err(
          ConnectionError(
            if frame.payload.length() % 6 != 0 {
              FrameSizeError
            } else {
              ProtocolError
            },
            "invalid SETTINGS frame",
          ),
        )
      }
      if (h.flags & H2_FLAGS_ACK) == 0 {
        let mut offset = 0
        while offset < frame.payload.length() {
          let id = ((frame.payload[offset].to_int() & 0xff) << 8) |
            (frame.payload[offset + 1].to_int() & 0xff)
          let value = u32(frame.payload, offset + 2)
          match self.apply_setting(id, value) {
            Ok(_) => ()
            Err(error) => return Err(error)
          }
          offset += 6
        }
        actions.push(SendSettingsAck)
      }
    }
    H2_FRAME_PING => {
      if h.stream_id != 0 || frame.payload.length() != 8 {
        return Err(ConnectionError(FrameSizeError, "invalid PING frame"))
      }
      if (h.flags & H2_FLAGS_ACK) == 0 {
        actions.push(SendPingAck(frame.payload))
      }
    }
    H2_FRAME_GOAWAY => {
      if h.stream_id != 0 || frame.payload.length() < 8 {
        return Err(ConnectionError(FrameSizeError, "invalid GOAWAY frame"))
      }
      self.goaway_received = true
      actions.push(GoawayReceived(u31(frame.payload, 0), u32(frame.payload, 4)))
    }
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
        if self.connection_send_window + increment > 0x7fffffff {
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
        if stream.send_window + increment > 0x7fffffff {
          return Err(
            StreamError(h.stream_id, FlowControlError, "stream window overflow"),
          )
        }
        stream.send_window += increment
      }
      actions.push(WindowAvailable(h.stream_id, increment))
    }
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
          if active >= self.local_settings.max_concurrent_streams {
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
            return Err(
              ConnectionError(ProtocolError, "invalid new remote stream id"),
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
      }
      let end_headers = (h.flags & H2_FLAGS_END_HEADERS) != 0
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
      if end_headers {
        self.continuation_stream = None
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
      self.connection_recv_window -= h.length
      stream.recv_window -= h.length
      if self.connection_recv_window < 0 {
        return Err(
          ConnectionError(
            FlowControlError,
            "connection receive window exhausted",
          ),
        )
      }
      if stream.recv_window < 0 {
        return Err(
          StreamError(
            h.stream_id,
            FlowControlError,
            "stream receive window exhausted",
          ),
        )
      }
      let end_stream = (h.flags & H2_FLAGS_END_STREAM) != 0
      if end_stream {
        close_remote_side(stream)
      }
      let data = if (h.flags & H2_FLAGS_PADDED) != 0 {
        let padding = frame.payload[0].to_int()
        frame.payload[1:frame.payload.length() - padding].to_owned()
      } else {
        frame.payload
      }
      actions.push(DataReceived(h.stream_id, data, end_stream))
    }
    H2_FRAME_RST_STREAM => {
      if h.stream_id == 0 || frame.payload.length() != 4 {
        return Err(ConnectionError(FrameSizeError, "invalid RST_STREAM"))
      }
      let stream = match self.streams.get(h.stream_id) {
        Some(value) => value
        None =>
          return Err(
            ConnectionError(ProtocolError, "RST_STREAM on idle stream"),
          )
      }
      stream.state = Closed
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
      } else if frame.payload.length() < 4 {
        return Err(ConnectionError(FrameSizeError, "invalid PUSH_PROMISE"))
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
    None =>
      return Err(
        StreamError(stream_id, StreamClosed, "capacity for unknown stream"),
      )
  }
  if self.connection_recv_window + amount > 0x7fffffff ||
    stream.recv_window + amount > 0x7fffffff {
    return Err(ConnectionError(FlowControlError, "receive window overflow"))
  }
  self.connection_recv_window += amount
  stream.recv_window += amount
  Ok([SendWindowUpdate(0, amount), SendWindowUpdate(stream_id, amount)])
}

///|
pub fn H2Connection::reserve_send_capacity(
  self : H2Connection,
  stream_id : Int,
  requested : Int,
) -> Result[Int, H2ProtocolError] {
  let stream = match self.streams.get(stream_id) {
    Some(value) => value
    None =>
      return Err(StreamError(stream_id, StreamClosed, "send on unknown stream"))
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

///|
pub fn H2Connection::finish_local_stream(
  self : H2Connection,
  stream_id : Int,
) -> Result[Unit, H2ProtocolError] {
  match self.streams.get(stream_id) {
    None => Err(StreamError(stream_id, StreamClosed, "unknown stream"))
    Some(stream) => {
      close_local_side(stream)
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
      Ok(())
    }
  }
}

///|
pub fn H2Connection::stream_state(
  self : H2Connection,
  stream_id : Int,
) -> H2StreamState? {
  self.streams.get(stream_id).map(fn(stream) { stream.state })
}
