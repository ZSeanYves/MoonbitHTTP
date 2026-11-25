///|
/// One authenticated QUIC connection drives one HTTP/3 session. The owner
/// delivers TLS-driver actions in order and transmits each outgoing datagram.
#derive(Eq, Debug)
pub(all) enum Http3SessionAction {
  Transport(@quic.QuicDriverAction)
  Message(H3Action)
  StreamFailed(Int64, H3ErrorCode)
  Failed(Http3SessionError)
}

///|
#derive(Eq, Debug)
pub(all) suberror Http3SessionError {
  Http3Protocol(Http3Error)
  Http3Transport(@quic.QuicError)
}

///|
pub struct Http3Session {
  priv quic : @quic.QuicDatagramDriver
  priv driver : Http3Driver
  priv messages : Map[Int64, H3RequestStreamState]
  priv writes : H3WriteQueue
  priv control : H3WriteQueue
  priv resets : Map[Int64, H3ErrorCode]
  priv stops : Map[Int64, H3ErrorCode]
  priv decoder_cancellations : Map[Int64, Bytes]
  priv mut sent_goaway : Int64?
  priv mut withheld : Map[Int64, Int32]?
  priv mut initialized : Bool
  priv mut ended : Bool
}

///|
/// Reserve one bounded queue for application frames and another for critical
/// stream instructions. Each may retain at most limits.max_buffer_bytes
/// bytes. The critical queue reserves at least three entries for startup.
pub fn[P] Http3Session::new(
  tls : @quic.QuicTlsDriver[P],
  limits~ : @types.Limits = @types.Limits::defaults(),
  qpack_limits~ : QpackLimits = QpackLimits::defaults(),
  max_pending_writes~ : Int32 = 1024,
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
    decoder_cancellations: Map([]),
    sent_goaway: None,
    withheld: None,
    initialized: false,
    ended: false,
  })
}

///|
pub fn Http3Session::ended(self : Http3Session) -> Bool {
  self.ended
}

///|
/// Latest boundary received on the peer's control stream.
pub fn Http3Session::peer_goaway(self : Http3Session) -> Int64? {
  self.driver.connection.goaway_id
}

///|
pub fn peer_closed_normally(connection : @quic.QuicConnection) -> Bool {
  match connection.peer_close() {
    Some(TransportClose(0L, _)) => true
    Some(ApplicationClose(code, _)) => code == H3NoError.wire_value()
    _ => false
  }
}

///|
fn H3ErrorCode::close_frame(self : H3ErrorCode) -> @quic.QuicFrame {
  ConnectionClose(false, self.wire_value(), 0L, b"")
}

///|
fn Http3Session::initialize(
  self : Http3Session,
) -> Unit raise Http3SessionError {
  if self.initialized || self.quic.state() != Established {
    return
  }
  let actions = self.driver
    .initial_stream_actions()
    .map_err(e => Http3Protocol(e))
    .unwrap_or_error()
  for action in actions {
    if action is SendOnStream(expected, bytes, fin) {
      let id = self.quic
        .open_unidirectional_stream()
        .map_err(e => Http3Transport(e))
        .unwrap_or_error()
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
    if self.sent_goaway is Some(first) && id >= first {
      raise Http3StreamError(
        id,
        H3RequestRejected,
        "request arrived after GOAWAY",
      )
    }
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
fn Http3Session::discard_input(
  self : Http3Session,
  id : Int64,
) -> Unit raise Http3Error {
  // Cancelling a request must release its resources even when the critical
  // stream has no write slots. Retain one small decoder instruction per ID.
  if !self.decoder_cancellations.contains(id) {
    let limit = self.driver.connection.limits.max_streams
    if self.decoder_cancellations.length() >= limit {
      raise Http3LimitExceeded("HTTP/3 pending stream cancellations", limit)
    }
    self.decoder_cancellations[id] = qpack_stream_cancellation(id).unwrap_or_error()
  }
  if self.withheld is Some(credit) {
    credit.remove(id)
  }
  self.driver.forget_request_input(id)
}

///|
/// Stop reading the remainder of a message. H3_NO_ERROR lets the peer finish
/// receiving a successful early response while its upload is interrupted.
pub fn Http3Session::stop_reading(
  self : Http3Session,
  id : Int64,
) -> Result[Unit, Http3Error] {
  if self.ended || self.driver.connection.stream_phase(id) is None {
    return Ok(())
  }
  try {
    self.discard_input(id)
    self.stops[id] = H3NoError
    Ok(())
  } catch {
    error => Err(error)
  }
}

///|
fn Http3Session::abort_stream(
  self : Http3Session,
  id : Int64,
  code : H3ErrorCode,
) -> Unit raise Http3Error {
  if !self.stops.contains(id) {
    self.discard_input(id)
    self.stops[id] = code
  }
  self.writes.drop(id)
  self.messages.remove(id)
  self.resets[id] = code
}

///|
/// Cancel both directions. The next advance sends pending control frames.
pub fn Http3Session::cancel(
  self : Http3Session,
  id : Int64,
  code~ : H3ErrorCode = H3RequestCancelled,
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
    self.abort_stream(id, code)
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
        if self.withheld is Some(credit) {
          credit.remove(id)
        }
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
      let result = if self.stops.contains(id) {
        Ok([])
      } else if self.driver.connection.role == H3Server &&
        (id & 3L) == 0L &&
        self.sent_goaway is Some(first) &&
        id >= first {
        self.abort_stream(id, H3RequestRejected) catch {
          error => raise Http3Protocol(error)
        }
        out.push(StreamFailed(id, H3RequestRejected))
        Ok([])
      } else {
        self.driver.on_stream_data(id, bytes, fin)
      }
      let mut immediate = bytes.length()
      if self.withheld is Some(credit) && result is Ok(events) {
        // Framing and QPACK instructions advance independently of a body
        // consumer. Replayed sections from another stream already had credit.
        for event in events {
          if event is Event(H3DataReceived(stream, data)) && stream == id {
            immediate -= data.length().min(immediate)
          }
        }
        if immediate < bytes.length() {
          credit[id] = credit.get(id).unwrap_or(0) +
            (bytes.length() - immediate)
        }
      }
      self.quic
      .connection()
      .consume_stream_data(id, immediate)
      .map_err(e => Http3Transport(e))
      .unwrap_or_error()
      result
    }
    StreamReset(id, _) => {
      out.push(Transport(action))
      if (id & 2L) == 0L {
        self.discard_input(id) catch {
          error => raise Http3Protocol(error)
        }
        return
      }
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
  self.dispatch(result.unwrap_or_error(), out) catch {
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
    self.initialize()
    let terminal = self.quic.state() == Closed || self.quic.state() == Draining
    for action in actions {
      if action is SendDatagram(_, _) {
        continue
      }
      if action is ConnectionClosed(_, _) {
        out.push(Transport(action))
        break
      }
      if !terminal || self.initialized {
        self.receive(action, out)
      }
    }
    if terminal {
      self.ended = true
      return out
    }
    if self.initialized {
      if !self.decoder_cancellations.is_empty() {
        // Snapshot only the IDs moved into the write queue this turn.
        let queued = []
        for id, bytes in self.decoder_cancellations {
          self.control.admit(bytes.length()) catch {
            Http3WriteBlocked => break
            error => raise Http3Protocol(error)
          }
          self.control.push(
            self.driver.local_qpack_decoder_stream,
            bytes,
            false,
          )
          queued.push(id)
        }
        for id in queued {
          self.decoder_cancellations.remove(id)
        }
      }
      self.flush(out, now_ms) catch {
        error => raise Http3Transport(error)
      }
    }
  } catch {
    error => {
      self.ended = true
      let code = match error {
        Http3Protocol(Http3ConnectionError(code, _)) => code
        Http3Protocol(Http3LimitExceeded(_, _) | Http3WriteBlocked) =>
          H3ExcessiveLoad
        Http3Protocol(Http3UnexpectedEof(_)) => H3FrameError
        _ => H3InternalError
      }
      if self.quic.state() == Established &&
        self.quic.send_frames(Application, [code.close_frame()], now_ms)
        is Ok(packet) {
        out.push(Transport(packet))
      }
      out.push(Failed(error))
    }
  }
  out
}

///|
/// Terminate this session and reject further application writes. When keys are
/// available the owner sends the returned application CONNECTION_CLOSE.
/// The default code reports an orderly HTTP/3 shutdown.
pub fn Http3Session::close(
  self : Http3Session,
  now_ms : Int64,
  code~ : H3ErrorCode = H3NoError,
) -> Result[@quic.QuicDriverAction?, @quic.QuicError] {
  if self.ended {
    return Ok(None)
  }
  self.ended = true
  if self.quic.state() != Established {
    return Ok(None)
  }
  self.quic
  .send_frames(Application, [code.close_frame()], now_ms)
  .map(packet => Some(packet))
}

///|
/// Include queued frames and writes handed to QUIC but still unacknowledged.
pub fn Http3Session::writes_pending(self : Http3Session) -> Bool {
  self.writes.count != 0 ||
  !self.decoder_cancellations.is_empty() ||
  self.control.count != 0 ||
  !self.stops.is_empty() ||
  !self.resets.is_empty() ||
  self.quic.connection().stream_writes_pending()
}

///|
/// Withhold QUIC receive credit for subsequently delivered body bytes until
/// the consumer reads or discards them. Framing and critical streams keep
/// their automatic credit. Call once before driving a streaming application.
pub fn Http3Session::defer_body_credit(self : Http3Session) -> Unit {
  if self.withheld is None {
    self.withheld = Some(Map([]))
  }
}

///|
/// Return credit for a delivered body chunk. Buffered QPACK replays and
/// bytes delivered before deferred mode can already have received credit.
pub fn Http3Session::consume_body(
  self : Http3Session,
  id : Int64,
  count : Int32,
) -> Result[Unit, @quic.QuicError] {
  if count < 0 {
    return Err(InvalidFrame("negative HTTP/3 consumption count"))
  }
  guard self.withheld is Some(credit) && credit.get(id) is Some(held) else {
    return Ok(())
  }
  let consumed = count.min(held)
  match self.quic.connection().consume_stream_data(id, consumed) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  if held == consumed {
    credit.remove(id)
  } else {
    credit[id] = held - consumed
  }
  Ok(())
}
