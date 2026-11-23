///|
fn H2ClientShared::closed_error(_self : H2ClientShared) -> Error {
  @http2.H2ProtocolError::ConnectionError(
    Cancel,
    "HTTP/2 client connection is closed",
  )
}

///|
fn H2ClientShared::release_stream(
  self : H2ClientShared,
  stream : H2ClientStream,
) -> Unit {
  if stream.request_finished && stream.response_finished && !stream.released {
    stream.released = true
    self.streams.remove(stream.id)
    self.blocked.remove(stream.id)
    self.admission.signal()
    if self.streams.is_empty() {
      (self.state_changed)()
    }
  }
}

///|
fn H2ClientShared::fail_stream(
  self : H2ClientShared,
  stream : H2ClientStream,
  error : Error,
) -> Unit {
  stream.request_finished = true
  stream.response_ended = true
  stream.response_finished = true
  self.discard_capacity(stream.credit.retire())
  if stream.upload is Some(task) {
    task.cancel()
  }
  stream.body.fail(error)
  stream.head.close(error~)
  stream.window_signal.broadcast()
  self.release_stream(stream)
}

///|
fn H2ClientShared::discard_capacity(
  self : H2ClientShared,
  amount : Int32,
) -> Unit {
  if amount > 0 && self.failure is None {
    self.discarded_capacity += amount
    ignore(self.blocked_signal.try_put(()) catch { _ => false })
  }
}

///|
async fn H2ClientShared::write_window_updates(
  self : H2ClientShared,
  updates : Array[@http2.H2Action],
) -> Unit {
  self.write_lock.acquire()
  defer self.write_lock.release()
  // Completed bodies remain readable after the peer closes. Their queued
  // credit no longer needs a wire update once the connection is closed.
  if self.failure is Some(_) {
    return
  }
  for update in updates {
    if update is SendWindowUpdate(id, value) {
      let encoded = match @http2.encode_window_update(id, value) {
        Ok(value) => value
        Err(error) => raise error
      }
      self.write_locked(encoded)
    }
  }
}

///|
async fn H2ClientShared::release_discarded_capacity(
  self : H2ClientShared,
) -> Unit {
  if self.failure is Some(_) {
    return
  }
  let updates = {
    self.runtime_lock.acquire()
    defer self.runtime_lock.release()
    let updates = match self.runtime.release_discarded_capacity() {
      Ok(value) => value
      Err(error) => raise error
    }
    let amount = self.discarded_capacity
    if amount > 0 {
      let update = match self.runtime.release_connection_capacity(amount) {
        Ok(value) => value
        Err(error) => raise error
      }
      self.discarded_capacity = 0
      updates.push(update)
    }
    updates
  }
  self.write_window_updates(updates)
}

///|
fn H2ClientShared::close_with(self : H2ClientShared, error : Error?) -> Unit {
  if self.failure is None {
    let failure = error.unwrap_or_else(fn() { self.closed_error() })
    self.failure = Some(failure)
    let active : Array[H2ClientStream] = []
    for stream in self.streams.values() {
      active.push(stream)
    }
    for stream in active {
      self.fail_stream(stream, failure)
    }
    (self.state_changed)()
    self.blocked_signal.close(error=failure)
    self.admission.broadcast()
  }
  if !self.close_notified {
    self.close_notified = true
    if self.config.close_callback is Some(callback) {
      callback(error)
    }
  }
}

///|
async fn H2ClientShared::write_bytes(
  self : H2ClientShared,
  bytes : Bytes,
) -> Unit {
  self.write_lock.acquire()
  defer self.write_lock.release()
  self.write_locked(bytes)
}

///|
/// An interrupted partial frame makes the entire connection unusable. All
/// writers check this under the shared lock before emitting subsequent bytes.
async fn H2ClientShared::write_locked(
  self : H2ClientShared,
  bytes : Bytes,
) -> Unit {
  if self.failure is Some(_) {
    raise self.closed_error()
  }
  errdefer self.close_with(
    Some(
      @http2.H2ProtocolError::ConnectionError(
        Cancel,
        "HTTP/2 frame write interrupted",
      ),
    ),
  )
  (self.write)(bytes)
}

///|
/// HPACK mutations and the resulting bytes share the wire's serialization
/// point; parallel streams cannot encode in a different order from writes.
async fn H2ClientShared::write_headers(
  self : H2ClientShared,
  encode : () -> Result[Bytes, @http2.H2ProtocolError],
) -> Unit {
  self.write_lock.acquire()
  defer self.write_lock.release()
  let bytes = match encode() {
    Ok(value) => value
    Err(error) => raise error
  }
  self.write_locked(bytes)
}

///|
async fn H2ClientShared::release_capacity(
  self : H2ClientShared,
  stream_id : Int32,
  amount : Int32,
) -> Unit {
  if self.failure is Some(_) {
    return
  }
  self.runtime_lock.acquire()
  let updates = match self.runtime.release_capacity(stream_id, amount) {
    Ok(value) => value
    Err(error) => {
      self.runtime_lock.release()
      raise error
    }
  }
  self.runtime_lock.release()
  self.write_window_updates(updates)
  if self.failure is None {
    self.blocked_signal.put(())
  }
}

///|
/// Claim body-consumption credit only after the write lock is held. A body
/// cancellation can retire the credit while this callback waits for another
/// writer; claiming it before that wait would lose the peer-visible window.
async fn H2ClientShared::release_consumed_capacity(
  self : H2ClientShared,
  stream_id : Int32,
  credit : H2ReceiveCredit,
  amount : Int32,
) -> Unit {
  if self.failure is Some(_) || amount <= 0 {
    return
  }
  self.write_lock.acquire()
  defer self.write_lock.release()
  if self.failure is Some(_) {
    return
  }
  self.runtime_lock.acquire()
  defer self.runtime_lock.release()
  let claimed = credit.consume(amount)
  if claimed == 0 {
    return
  }
  let updates = match self.runtime.release_capacity(stream_id, claimed) {
    Ok(value) => value
    Err(error) => raise error
  }
  for update in updates {
    if update is SendWindowUpdate(id, value) {
      let encoded = match @http2.encode_window_update(id, value) {
        Ok(value) => value
        Err(error) => raise error
      }
      self.write_locked(encoded)
    }
  }
  if self.failure is None {
    self.blocked_signal.put(())
  }
}

///|
async fn H2ClientShared::reset_stream_with_error(
  self : H2ClientShared,
  stream_id : Int32,
  code : @http2.H2ErrorCode,
  error : Error,
) -> Unit {
  if self.failure is Some(_) {
    return
  }
  if self.streams.get(stream_id) is Some(stream) {
    self.fail_stream(stream, error)
  }
  self.runtime_lock.acquire()
  ignore(self.runtime.reset_stream(stream_id))
  self.runtime_lock.release()
  self.admission.signal()
  let encoded = match @http2.encode_rst_stream(stream_id, code) {
    Ok(value) => value
    Err(error) => raise error
  }
  self.write_bytes(encoded)
}

///|
async fn H2ClientShared::reset_stream(
  self : H2ClientShared,
  stream_id : Int32,
  code : @http2.H2ErrorCode,
  message : String,
) -> Unit {
  self.reset_stream_with_error(
    stream_id,
    code,
    @http2.H2ProtocolError::StreamError(stream_id, code, message),
  )
}

///|
/// Retire the stream immediately. A connection task owns the wire reset so a
/// cancelled producer or consumer never has to wait for the writer lock.
fn H2ClientShared::cancel_stream(
  self : H2ClientShared,
  stream_id : Int32,
  error : Error,
) -> Unit {
  guard self.streams.get(stream_id) is Some(stream) else { return }
  self.fail_stream(stream, error)
  ignore(
    (self.spawn)(async fn() {
      self.reset_stream_with_error(stream_id, Cancel, error) catch {
        failure => self.close_with(Some(failure))
      }
    }),
  )
}

///|
fn H2ClientShared::drain_blocked(self : H2ClientShared) -> Unit {
  for stream_id, queue in self.blocked {
    guard self.streams.get(stream_id) is Some(stream) else {
      self.blocked.remove(stream_id)
      continue
    }
    while queue.front() is Some(blocked) {
      let accepted = match blocked {
        BlockedData(data, _) =>
          stream.body.try_push(Data(data)) catch {
            error => {
              self.fail_stream(stream, error)
              false
            }
          }
        BlockedTrailers(trailers) =>
          stream.body.try_push(Trailers(trailers)) catch {
            error => {
              self.fail_stream(stream, error)
              false
            }
          }
      }
      if accepted {
        ignore(queue.pop_front())
        match blocked {
          BlockedData(_, true) | BlockedTrailers(_) => {
            stream.response_finished = true
            stream.body.finish()
            self.release_stream(stream)
          }
          BlockedData(_, false) => ()
        }
      } else {
        break
      }
    }
    if queue.is_empty() {
      self.blocked.remove(stream_id)
    }
  }
}

///|
fn H2ClientShared::queue_blocked(
  self : H2ClientShared,
  stream_id : Int32,
  frame : H2ClientBlockedFrame,
) -> Unit {
  let queue = self.blocked.get_or_init(stream_id, fn() { Deque([]) })
  queue.push_back(frame)
}
