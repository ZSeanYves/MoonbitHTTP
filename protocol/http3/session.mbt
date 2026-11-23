///|
/// One authenticated QUIC connection drives one HTTP/3 session. The owner
/// delivers TLS-driver actions in order and transmits each outgoing datagram.
pub(all) enum Http3SessionAction {
  Transport(@quic.QuicDriverAction)
  Message(H3Action)
  StreamFailed(Int64, H3ErrorCode)
  Failed(Http3SessionError)
} derive(Eq, Debug)

///|
pub(all) suberror Http3SessionError {
  Http3Protocol(Http3Error)
  Http3Transport(@quic.QuicError)
} derive(Eq, Debug)

///|
pub struct Http3Session {
  priv quic : @quic.QuicDatagramDriver
  priv driver : Http3Driver
  priv messages : Map[Int64, H3RequestStreamState]
  priv writes : H3WriteQueue
  priv control : H3WriteQueue
  priv resets : Map[Int64, H3ErrorCode]
  priv stops : Map[Int64, H3ErrorCode]
  priv mut initialized : Bool
  priv mut ended : Bool
}

///|
/// Reserve one bounded queue for application frames and another for critical
/// stream instructions. Each may retain at most limits.max_buffer_bytes
/// bytes. The critical queue reserves at least three entries for startup.
pub fn[P] Http3Session::new(
  tls : @quic.QuicTlsDriver[P],
  limits? : @types.Limits = @types.Limits::defaults(),
  qpack_limits? : QpackLimits = QpackLimits::defaults(),
  max_pending_writes? : Int = 1024,
) -> Result[Http3Session, Http3Error] {
  if max_pending_writes <= 0 {
    return Err(
      Http3LimitExceeded("HTTP/3 pending write capacity", max_pending_writes),
    )
  }
  let quic = tls.datagram_driver()
  let role = if quic.role() == Client { H3Client } else { H3Server }
  Http3Driver::new(role, limits~, qpack_limits~).map(driver => {
    quic,
    driver,
    messages: Map([]),
    writes: H3WriteQueue::new(limits.max_buffer_bytes, max_pending_writes),
    control: H3WriteQueue::new(
      limits.max_buffer_bytes,
      max_pending_writes.max(3),
    ),
    resets: Map([]),
    stops: Map([]),
    initialized: false,
    ended: false,
  })
}

///|
pub fn Http3Session::ended(self : Http3Session) -> Bool {
  self.ended
}

///|
fn Http3Session::initialize(
  self : Http3Session,
) -> Unit raise Http3SessionError {
  if self.initialized || self.quic.state() != Established {
    return
  }
  let actions = h3_value(
    self.driver.initial_stream_actions().map_err(e => Http3Protocol(e)),
  )
  for action in actions {
    if action is SendOnStream(expected, bytes, fin) {
      let id = h3_value(
        self.quic.open_unidirectional_stream().map_err(e => Http3Transport(e)),
      )
      if expected != id {
        raise Http3Protocol(
          Http3ConnectionError(
            H3StreamCreationError,
            "critical stream already allocated",
          ),
        )
      }
      self.control.admit(bytes.length()) catch {
        error => raise Http3Protocol(error)
      }
      self.control.push(id, bytes, fin)
    }
  }
  self.initialized = true
}

///|
fn Http3Session::record(
  self : Http3Session,
  event : H3Action,
) -> Unit raise Http3Error {
  if self.driver.connection.role == H3Server &&
    event is H3HeadersReceived(id, fields, false, false) &&
    self.quic.connection().stream_writable(id) {
    if self.messages.length() >=
      self.driver.connection.limits.max_concurrent_requests {
      raise Http3StreamError(
        id,
        H3RequestRejected,
        "concurrent response limit reached",
      )
    }
    self.messages[id] = H3RequestStreamState::new(
      id,
      H3IncomingResponse(h3_response_method(fields)),
    )
  }
}

///|
// Only HEAD changes response DATA semantics in the message state machine.
fn h3_response_method(fields : Array[QpackField]) -> String? {
  if fields.any(f => f.name == ":method" && f.value == b"HEAD") {
    Some("HEAD")
  } else {
    None
  }
}

///|
fn Http3Session::abort_stream(
  self : Http3Session,
  id : Int64,
  code : H3ErrorCode,
) -> Unit raise Http3Error {
  // Cancellation can be retried after control backpressure clears. Check the
  // exact QPACK instruction size before releasing receive state.
  let bytes = h3_value(qpack_stream_cancellation(id))
  self.control.admit(bytes.length())
  self.driver.forget_request_input(id)
  self.control.push(self.driver.local_qpack_decoder_stream, bytes, false)
  self.writes.drop(id)
  self.messages.remove(id)
  self.resets[id] = code
  self.stops[id] = code
}

///|
/// Cancel both directions. The next advance sends pending control frames.
pub fn Http3Session::cancel(
  self : Http3Session,
  id : Int64,
) -> Result[Unit, Http3Error] {
  if self.ended ||
    (
      !self.messages.contains(id) &&
      self.driver.connection.stream_phase(id) is None &&
      !self.writes.streams.contains(id)
    ) {
    return Err(
      Http3StreamError(id, H3RequestCancelled, "request is no longer active"),
    )
  }
  try {
    self.abort_stream(id, H3RequestCancelled)
    Ok(())
  } catch {
    error => Err(error)
  }
}

///|
fn Http3Session::dispatch(
  self : Http3Session,
  actions : Array[H3DriverAction],
  out : Array[Http3SessionAction],
) -> Unit raise Http3Error {
  for action in actions {
    match action {
      Event(event) => {
        match event {
          H3HeadersReceived(id, _, _, _)
          | H3DataReceived(id, _)
          | H3MessageFinished(id) if self.stops.contains(id) => continue
          _ => ()
        }
        self.record(event) catch {
          Http3StreamError(id, code, _) => {
            self.abort_stream(id, code)
            out.push(StreamFailed(id, code))
            continue
          }
          error => raise error
        }
        out.push(Message(event))
      }
      SendOnStream(id, bytes, fin) => {
        self.control.admit(bytes.length())
        self.control.push(id, bytes, fin)
      }
      ResetStream(id, code) => {
        self.writes.drop(id)
        self.messages.remove(id)
        self.resets[id] = code
        out.push(StreamFailed(id, code))
      }
      StopSending(id, code) => self.stops[id] = code
      CloseConnection(code) =>
        raise Http3ConnectionError(code, "HTTP/3 connection closed")
      QpackStreamReady(_) => ()
    }
  }
}

///|
fn Http3Session::receive(
  self : Http3Session,
  action : @quic.QuicDriverAction,
  out : Array[Http3SessionAction],
) -> Unit raise Http3SessionError {
  let result = match action {
    StreamData(id, bytes, fin) => {
      h3_value(
        self.quic
        .connection()
        .consume_stream_data(id, bytes.length())
        .map_err(e => Http3Transport(e)),
      )
      if self.stops.contains(id) {
        return
      }
      self.driver.on_stream_data(id, bytes, fin)
    }
    StreamReset(id, _) => {
      out.push(Transport(action))
      self.driver.on_stream_reset(id)
    }
    SendStopped(id, _) => {
      self.messages.remove(id)
      self.writes.drop(id)
      out.push(Transport(action))
      self.driver.on_stop_sending(id)
    }
    _ => {
      out.push(Transport(action))
      return
    }
  }
  self.dispatch(h3_value(result), out) catch {
    Http3StreamError(id, code, _) => {
      self.abort_stream(id, code) catch {
        error => raise Http3Protocol(error)
      }
      out.push(StreamFailed(id, code))
    }
    error => raise Http3Protocol(error)
  }
}

///|
fn Http3Session::flush(
  self : Http3Session,
  out : Array[Http3SessionAction],
  now_ms : Int64,
) -> Unit raise @quic.QuicError {
  let done = []
  for id, code in self.resets {
    match self.quic.reset_stream(id, code.wire_value(), now_ms) {
      Ok(packet) => out.push(Transport(packet))
      Err(StreamClosed(_)) => ()
      Err(error) if error.send_blocked() => continue
      Err(error) => raise error
    }
    done.push(id)
  }
  for id in done {
    self.resets.remove(id)
  }
  done.clear()
  for id, code in self.stops {
    match self.quic.stop_sending(id, code.wire_value(), now_ms) {
      Ok(Some(packet)) => out.push(Transport(packet))
      Ok(None) | Err(StreamClosed(_)) => ()
      Err(error) if error.send_blocked() => continue
      Err(error) => raise error
    }
    done.push(id)
  }
  for id in done {
    self.stops.remove(id)
  }
  self.control.flush(self.quic, out, now_ms)
  self.writes.flush(self.quic, out, now_ms)
}

///|
/// Feed start/receive/poll actions from the owning TLS driver. An empty batch
/// flushes application writes. Process output in order, including datagrams
/// returned alongside a terminal notification.
pub fn Http3Session::advance(
  self : Http3Session,
  actions : Array[@quic.QuicDriverAction],
  now_ms : Int64,
) -> Array[Http3SessionAction] {
  let out = []
  try {
    for action in actions {
      if action is SendDatagram(_, _) {
        out.push(Transport(action))
      }
    }
    if self.ended {
      return out
    }
    if self.quic.state() == Closed || self.quic.state() == Draining {
      self.ended = true
      for action in actions {
        if action is ConnectionClosed(_, _) {
          out.push(Transport(action))
        }
      }
      return out
    }
    self.initialize()
    for action in actions {
      if action is SendDatagram(_, _) {
        continue
      }
      self.receive(action, out)
    }
    if self.initialized {
      self.flush(out, now_ms) catch {
        error => raise Http3Transport(error)
      }
    }
  } catch {
    error => {
      self.ended = true
      let code = match error {
        Http3Protocol(Http3ConnectionError(code, _)) => code
        Http3Protocol(Http3LimitExceeded(_, _)) => H3ExcessiveLoad
        Http3Protocol(Http3UnexpectedEof(_)) => H3FrameError
        _ => H3InternalError
      }
      if self.quic.state() == Established &&
        self.quic.send_frames(
          Application,
          [ConnectionClose(true, code.wire_value(), 0L, b"")],
          now_ms,
        )
        is Ok(packet) {
        out.push(Transport(packet))
      }
      out.push(Failed(error))
    }
  }
  out
}
