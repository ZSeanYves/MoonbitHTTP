///|
priv enum H3MessagePart {
  Headers(Array[QpackField])
  Data(Bytes)
  End
}

///|
/// Validate the next message state on a copy. Neither a rejected frame nor a
/// busy output queue changes the caller's position in the message.
fn Http3Session::prepare(
  self : Http3Session,
  state : H3RequestStreamState,
  part : H3MessagePart,
  fin : Bool,
) -> (H3RequestStreamState, Bytes) raise Http3Error {
  let next = { ..state, phase: state.phase, }
  let conn = self.driver.connection
  match part {
    Headers(fields) =>
      ignore(
        next
        .receive_headers(fields, conn.peer_settings.enable_connect_protocol)
        .unwrap_or_error(),
      )
    Data(data) =>
      next.receive_data(data, conn.limits.max_body_bytes).unwrap_or_error()
    End => ()
  }
  if fin {
    next.finish().unwrap_or_error()
  }
  let bytes = match part {
    Headers(fields) => {
      let bytes = conn
        .encode_validated_headers(next.id, fields)
        .unwrap_or_error()
      self.writes.admit(bytes.length())
      bytes
    }
    Data(data) => {
      self.writes.admit(h3_driver_blocked_frame_bytes(H3Data(data)))
      encode_http3_frame(H3Data(data)).unwrap_or_error()
    }
    End => {
      self.writes.admit(0)
      b""
    }
  }
  (next, bytes)
}

///|
fn Http3Session::commit(
  self : Http3Session,
  next : H3RequestStreamState,
  bytes : Bytes,
  fin : Bool,
) -> Unit {
  self.writes.push(next.id, bytes, fin)
  if fin {
    self.messages.remove(next.id)
  } else {
    self.messages[next.id] = next
  }
}

///|
/// Open a client request with its first HEADERS. A refused QUIC stream or full
/// application queue leaves the next request identifier available for retry.
pub fn Http3Session::start_request(
  self : Http3Session,
  fields : Array[QpackField],
  fin~ : Bool = false,
) -> Result[Int64, Http3SessionError] {
  if self.ended || !self.initialized {
    return Err(
      Http3Protocol(
        Http3ConnectionError(
          H3RequestRejected,
          "session is not accepting requests",
        ),
      ),
    )
  }
  let conn = self.driver.connection
  try {
    let id = conn
      .next_request_id()
      .map_err(e => Http3Protocol(e))
      .unwrap_or_error()
    if self.messages.length() >= conn.limits.max_concurrent_requests {
      raise Http3Protocol(
        Http3LimitExceeded(
          "concurrent request writers",
          conn.limits.max_concurrent_requests,
        ),
      )
    }
    let state = H3RequestStreamState::new(id, H3IncomingRequest)
    let (next, bytes) = self.prepare(state, Headers(fields), fin) catch {
      e => raise Http3Protocol(e)
    }
    let request_method = h3_response_method(fields)
    let actual = self.quic
      .connection()
      .open_bidirectional_stream()
      .map_err(e => Http3Transport(e))
      .unwrap_or_error()
    if actual != id {
      self.ended = true
      raise Http3Protocol(
        Http3ConnectionError(
          H3StreamCreationError,
          "request stream already allocated",
        ),
      )
    }
    conn.register_request(id, request_method)
    self.commit(next, bytes, fin)
    Ok(id)
  } catch {
    e => Err(e)
  }
}

///|
/// True while the application can append another frame to this message.
/// A full output queue can still require retrying after advance.
pub fn Http3Session::can_write(self : Http3Session, id : Int64) -> Bool {
  !self.ended && self.messages.contains(id)
}

///|
fn Http3Session::write(
  self : Http3Session,
  id : Int64,
  part : H3MessagePart,
  fin : Bool,
) -> Result[Unit, Http3Error] {
  guard !self.ended && self.messages.get(id) is Some(state) else {
    return Err(
      Http3StreamError(id, H3RequestCancelled, "request stream is not writable"),
    )
  }
  try {
    let (next, bytes) = self.prepare(state, part, fin)
    self.commit(next, bytes, fin)
    Ok(())
  } catch {
    e => Err(e)
  }
}

///|
/// Queue response headers (including informational responses) or trailers.
pub fn Http3Session::send_headers(
  self : Http3Session,
  id : Int64,
  fields : Array[QpackField],
  fin~ : Bool = false,
) -> Result[Unit, Http3Error] {
  self.write(id, Headers(fields), fin)
}

///|
/// Queue one DATA frame. Split large bodies into chunks that fit the budget.
pub fn Http3Session::send_data(
  self : Http3Session,
  id : Int64,
  data : Bytes,
  fin~ : Bool = false,
) -> Result[Unit, Http3Error] {
  self.write(id, Data(data), fin)
}

///|
/// End a message without emitting an extra frame.
pub fn Http3Session::finish(
  self : Http3Session,
  id : Int64,
) -> Result[Unit, Http3Error] {
  self.write(id, End, true)
}

///|
/// Send GOAWAY with the first rejected request stream ID (server) or Push ID
/// (client). The caller must account for items already accepted. Further GOAWAYs
/// may lower that boundary. Retry Http3WriteBlocked after advancing the session.
pub fn Http3Session::send_goaway(
  self : Http3Session,
  first_rejected : Int64,
) -> Result[Unit, Http3Error] {
  if self.ended || !self.initialized {
    return Err(
      Http3ConnectionError(H3InternalError, "GOAWAY requires an open session"),
    )
  }
  if first_rejected < 0L ||
    first_rejected > @quic.QUIC_MAX_VARINT ||
    (self.driver.connection.role == H3Server && (first_rejected & 3L) != 0L) ||
    (self.sent_goaway is Some(previous) && first_rejected > previous) {
    return Err(Http3ConnectionError(H3IdError, "invalid GOAWAY boundary"))
  }
  if self.sent_goaway == Some(first_rejected) {
    return Ok(())
  }
  try {
    let frame = encode_http3_frame(H3Goaway(first_rejected)).unwrap_or_error()
    self.control.admit(frame.length())
    self.control.push(self.driver.local_control_stream, frame, false)
    self.sent_goaway = Some(first_rejected)
    Ok(())
  } catch {
    error => Err(error)
  }
}
