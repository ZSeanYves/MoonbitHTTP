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
/// Maximum positive HTTP/2 flow-control window.
const H2_MAX_WINDOW : Int = 0x7fffffff

///|
/// Minimum signed stream window after a SETTINGS decrease.
const H2_MIN_WINDOW : Int = -0x80000000

///|
/// Closed stream IDs are retained only long enough to preserve precise
/// post-close errors; flow-control records themselves are reclaimed.
const H2_CLOSED_STREAM_HISTORY : Int = 1024

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
fn H2Settings::from_limits(limits : @types.Limits) -> H2Settings {
  {
    header_table_size: limits.max_dynamic_table_bytes,
    enable_push: true,
    max_concurrent_streams: limits.max_streams.min(
      limits.max_concurrent_requests,
    ),
    initial_window_size: 65535,
    max_frame_size: H2_DEFAULT_MAX_FRAME_SIZE,
    max_header_list_size: limits.max_header_bytes,
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
  DataReceived(Int, Array[Byte], Bool, Int)
  StreamResetReceived(Int, Int)
  GoawayReceived(Int, Int)
  WindowAvailable(Int, Int)
  SendWindowUpdate(Int, Int)
}

///|
pub struct H2Connection {
  role : H2Role
  limits : @types.Limits
  local_settings : H2Settings
  peer_settings : H2Settings
  streams : Map[Int, H2Stream]
  closed_streams : Array[Int]
  mut connection_send_window : Int
  mut connection_recv_window : Int
  mut highest_remote_stream : Int
  mut next_local_stream : Int
  mut continuation_stream : Int?
  mut continuation_bytes : Int
  mut goaway_received : Bool
  mut goaway_last_stream : Int?
  mut failure : H2ProtocolError?
}

///|
pub fn H2Connection::new(
  role : H2Role,
  limits? : @types.Limits = @types.Limits::defaults(),
) -> H2Connection {
  {
    role,
    limits,
    local_settings: H2Settings::from_limits(limits),
    peer_settings: H2Settings::defaults(),
    streams: Map([]),
    closed_streams: [],
    connection_send_window: 65535,
    connection_recv_window: 65535,
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
/// Sets the bounded receive budget advertised to the peer before the first
/// stream is opened. The budget is shared by the connection and each stream.
pub fn H2Connection::set_local_initial_window(
  self : H2Connection,
  window : Int,
) -> Result[Unit, H2ProtocolError] {
  if window <= 0 || window > 0x7fffffff {
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
  self.local_settings.initial_window_size = window
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
fn h2_validate_frame_flags(
  typ : Int,
  flags : Int,
) -> Result[Unit, H2ProtocolError] {
  let allowed = match typ {
    H2_FRAME_DATA => H2_FLAGS_END_STREAM | H2_FLAGS_PADDED
    H2_FRAME_HEADERS =>
      H2_FLAGS_END_STREAM |
      H2_FLAGS_END_HEADERS |
      H2_FLAGS_PADDED |
      H2_FLAGS_PRIORITY
    H2_FRAME_PRIORITY => 0
    H2_FRAME_RST_STREAM => 0
    H2_FRAME_SETTINGS => H2_FLAGS_ACK
    H2_FRAME_PUSH_PROMISE => H2_FLAGS_END_HEADERS | H2_FLAGS_PADDED
    H2_FRAME_PING => H2_FLAGS_ACK
    H2_FRAME_GOAWAY => 0
    H2_FRAME_WINDOW_UPDATE => 0
    H2_FRAME_CONTINUATION => H2_FLAGS_END_HEADERS
    _ => 0xff
  }
  if typ < 0 || typ > 0xff || (flags & allowed) != flags {
    return Err(
      ConnectionError(ProtocolError, "frame contains unsupported flags"),
    )
  }
  Ok(())
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
    1 =>
      self.peer_settings.header_table_size = if value < 0 {
        self.limits.max_dynamic_table_bytes
      } else {
        value.min(self.limits.max_dynamic_table_bytes)
      }
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
    3 =>
      self.peer_settings.max_concurrent_streams = if value < 0 {
        self.limits.max_streams
      } else {
        value.min(self.limits.max_streams)
      }
    4 => {
      if value < 0 || value > 0x7fffffff {
        return Err(
          ConnectionError(FlowControlError, "invalid initial window size"),
        )
      }
      let delta = value - self.peer_settings.initial_window_size
      // Check every stream before mutating any stream so a bad SETTINGS
      // update cannot leave a partially changed connection.
      for stream in self.streams.values() {
        if (
            delta > 0 &&
            (
              delta > H2_MAX_WINDOW ||
              stream.send_window > H2_MAX_WINDOW - delta
            )
          ) ||
          (
            delta < 0 &&
            (
              delta < H2_MIN_WINDOW ||
              stream.send_window < H2_MIN_WINDOW - delta
            )
          ) {
          return Err(
            ConnectionError(
              FlowControlError,
              "stream window overflow after SETTINGS",
            ),
          )
        }
      }
      for stream in self.streams.values() {
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
    6 =>
      self.peer_settings.max_header_list_size = if value < 0 {
        self.limits.max_header_bytes
      } else {
        value.min(self.limits.max_header_bytes)
      }
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
  match h2_validate_frame_flags(h.typ, h.flags) {
    Ok(_) => ()
    Err(error) => return Err(error)
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
  let mut header_fragment_length = 0
  if h.typ == H2_FRAME_HEADERS {
    let mut offset = 0
    let mut padding = 0
    if (h.flags & H2_FLAGS_PADDED) != 0 {
      if frame.payload.is_empty() {
        return Err(ConnectionError(FrameSizeError, "invalid HEADERS padding"))
      }
      padding = frame.payload[0].to_int()
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
    header_fragment_length = frame.payload.length() - offset - padding
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
      if (frame.payload[0].to_int() & 0x80) != 0 {
        return Err(
          ConnectionError(ProtocolError, "GOAWAY stream id has reserved bit"),
        )
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
        StreamError(stream_id, _, _) =>
          if self.streams.get(stream_id) is Some(stream) {
            stream.state = Closed
            self.remove_closed_stream(stream_id)
          }
      }
      Err(error)
    }
    value => value
  }
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
