///|
const H2_MAX_QUEUED_CONTROLS = 32

///|
priv enum H2ControlItem {
  Frame(Bytes)
  WindowUpdates
}

///|
/// Only the writer drains this queue. Reserve one entry for all pending flow
/// credit so a burst of ordinary DATA cannot crowd out ACKs and stream resets.
priv struct H2ServerControl {
  queue : @aqueue.Queue[H2ControlItem]
  windows : Map[Int32, Int32]
  connection : @http2.H2Connection
  max_streams : Int32
  mut frames : Int32
}

///|
fn H2ServerControl::new(
  connection : @http2.H2Connection,
  max_streams : Int32,
) -> H2ServerControl {
  {
    queue: Queue(kind=Blocking(H2_MAX_QUEUED_CONTROLS + 1)),
    windows: Map([]),
    connection,
    max_streams,
    frames: 0,
  }
}

///|
fn H2ServerControl::frame(self : H2ServerControl, bytes : Bytes) -> Unit raise {
  if self.frames >= H2_MAX_QUEUED_CONTROLS || !self.queue.try_put(Frame(bytes)) {
    raise @http2.H2ProtocolError::ConnectionError(
      EnhanceYourCalm,
      "HTTP/2 control frame queue full",
    )
  }
  self.frames += 1
}

///|
fn H2ServerControl::needs_credit(self : H2ServerControl, id : Int32) -> Bool {
  id == 0 || self.connection.stream_state(id) is Some(Open | HalfClosedLocal)
}

///|
fn H2ServerControl::credit(
  self : H2ServerControl,
  action : @http2.H2Action,
) -> Unit raise {
  guard action is SendWindowUpdate(id, amount) && self.needs_credit(id) else {
    return
  }
  let pending = self.windows.get(id)
  let previous = pending.unwrap_or(0)
  if previous > 0x7fffffff - amount {
    raise @http2.H2ProtocolError::ConnectionError(
      FlowControlError,
      "pending receive credit overflow",
    )
  }
  if self.windows.is_empty() {
    // Ordinary frames cannot occupy this reserved slot.
    if !self.queue.try_put(WindowUpdates) {
      raise @http2.H2ProtocolError::ConnectionError(
        InternalError,
        "missing window-update queue slot",
      )
    }
  } else if pending is None && self.windows.length() > self.max_streams {
    // Closed stream IDs can accumulate while the writer waits. Retain only
    // the connection and streams whose peers may still send DATA.
    self.windows.retain((stream, _) => self.needs_credit(stream))
  }
  self.windows[id] = previous + amount
}

///|
/// Called under the wire write lock, so incoming credit remains coalescible
/// until this worker can actually write it. No application task owns the send.
fn H2ServerControl::take(
  self : H2ServerControl,
  item : H2ControlItem,
) -> Bytes raise {
  match item {
    Frame(bytes) => {
      self.frames -= 1
      bytes
    }
    WindowUpdates => {
      let bytes : Array[Byte] = []
      for id, amount in self.windows {
        if self.needs_credit(id) {
          match @http2.encode_window_update(id, amount) {
            Ok(frame) => copy_data(bytes, frame)
            Err(error) => raise error
          }
        }
      }
      self.windows.clear()
      Bytes::from_array(bytes)
    }
  }
}
