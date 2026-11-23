///|
/// Owns stream admission slots, queued request data and connection receive credit.
priv struct H2ServerStreams {
  mut input_ended : Bool
  mut discarded_capacity : Int32
  pending : Map[Int32, H2PendingRequest]
  blocked : Map[Int32, @deque.Deque[H2ServerBlockedFrame]]
  handlers : Map[Int32, H2HandlerTask]
  connection : @http2.H2Connection
  control : H2ServerControl
  write_lock : @async.Mutex
  window_signal : @cond_var.Cond
  blocked_signal : @aqueue.Queue[Unit]
}

///|
async fn H2ServerStreams::cancel_handler(
  self : H2ServerStreams,
  stream_id : Int32,
) -> Unit {
  if self.handlers.get(stream_id) is Some(handler) && handler.task is Some(task) {
    task.cancel()
    // Cancellation is complete only after wait returns. The task's defer
    // owns slot removal; unexpected failures still propagate via the group.
    task.wait() catch {
      _ => ()
    }
  }
}

///|
fn H2ServerStreams::release_discarded_data(
  self : H2ServerStreams,
  amount : Int32,
) -> Unit raise {
  if amount <= 0 {
    return
  }
  let update = match self.connection.release_connection_capacity(amount) {
    Ok(value) => value
    Err(error) => raise error
  }
  self.control.credit(update)
}

///|
async fn H2ServerStreams::release_consumed_data(
  self : H2ServerStreams,
  stream_id : Int32,
  credit : H2ReceiveCredit,
  amount : Int32,
) -> Unit {
  if amount <= 0 {
    return
  }
  // Claim body credit only after acquiring the write lock. If the body is
  // cancelled while another writer holds the lock, its on_cancel handler
  // retires the credit and this callback becomes a no-op.
  self.write_lock.acquire()
  defer self.write_lock.release()
  let claimed = credit.consume(amount)
  if claimed == 0 {
    return
  }
  let updates = match self.connection.release_capacity(stream_id, claimed) {
    Ok(value) => value
    Err(error) => raise error
  }
  for update in updates {
    self.control.credit(update)
  }
  self.blocked_signal.put(())
}

///|
fn H2ServerStreams::reset_stream_with_error(
  self : H2ServerStreams,
  stream_id : Int32,
  code : @http2.H2ErrorCode,
  failure : Error,
) -> Unit raise {
  ignore(self.connection.reset_stream(stream_id))
  self.remove_failed_stream(stream_id, failure)
  self.window_signal.broadcast()
  let encoded = match @http2.encode_rst_stream(stream_id, code) {
    Ok(value) => value
    Err(error) => raise error
  }
  self.control.frame(encoded)
}

///|
async fn H2ServerStreams::reset_stream(
  self : H2ServerStreams,
  stream_id : Int32,
  code : @http2.H2ErrorCode,
) -> Unit {
  self.reset_stream_with_error(
    stream_id,
    code,
    @http2.H2ProtocolError::StreamError(stream_id, code, "HTTP/2 stream reset"),
  )
  self.cancel_handler(stream_id)
}

///|
fn H2ServerStreams::finish_response(
  self : H2ServerStreams,
  stream_id : Int32,
) -> Unit raise {
  match self.connection.finish_local_stream(stream_id) {
    Ok(_) => ()
    Err(error) => raise error
  }
  // A response body can consume the request body lazily (for example an
  // echo/proxy service). Only discard unread input after that body ends.
  if self.pending.get(stream_id) is Some(value) {
    value.response_finished = true
    let unread = value.credit.retire()
    if unread > 0 {
      // A service may finish its response without reading all of the
      // request. Reclaim that connection credit exactly once.
      value.body.cancel(@body.BodyError::Cancelled)
      self.blocked.remove(stream_id)
      self.release_discarded_data(unread)
    }
    if value.request_ended {
      self.pending.remove(stream_id)
      self.blocked.remove(stream_id)
    }
  }
}

///|
fn H2ServerStreams::remove_failed_stream(
  self : H2ServerStreams,
  stream_id : Int32,
  failure : Error,
) -> Unit raise {
  let unread = match self.pending.get(stream_id) {
    Some(value) => {
      let amount = value.credit.retire()
      value.body.fail(failure)
      amount
    }
    None => 0
  }
  self.pending.remove(stream_id)
  self.blocked.remove(stream_id)
  self.release_discarded_data(unread)
}

///|
fn H2ServerStreams::make_body(
  self : H2ServerStreams,
  capacity : Int32,
  stream_id : Int32,
) -> (@body.BodyStream, H2ReceiveCredit) raise {
  let credit = H2ReceiveCredit::new()
  let body = match
    @body.BodyStream::new(
      capacity~,
      on_data_consumed=async fn(amount) {
        errdefer (if self.pending.contains(stream_id) {
          self.reset_stream_with_error(
            stream_id,
            Cancel,
            @http2.H2ProtocolError::StreamError(
              stream_id,
              Cancel,
              "request body credit release failed",
            ),
          ) catch {
            _ => ()
          }
        })
        self.release_consumed_data(stream_id, credit, amount)
      },
      on_cancel=fn(_) {
        if credit.retired {
          return
        }
        self.discarded_capacity += credit.retire()
        self.blocked.remove(stream_id)
        // Cancelling request input must not cancel an early response.
        ignore(self.blocked_signal.try_put(()) catch { _ => false })
      },
    ) {
    Ok(value) => value
    Err(error) => raise error
  }
  (body, credit)
}

///|
fn H2ServerStreams::drain_blocked(
  self : H2ServerStreams,
  dispatch : (Int32) -> Unit,
) -> Unit {
  for stream_id, queue in self.blocked {
    if self.pending.get(stream_id) is Some(request) {
      while queue.front() is Some(value) {
        let frame : @body.Frame = match value {
          BlockedData(data, _) => Data(data)
          BlockedTrailers(trailers) => Trailers(trailers)
        }
        let accepted = request.body.try_push(frame) catch {
          error => {
            request.body.fail(error)
            false
          }
        }
        if accepted {
          ignore(queue.pop_front())
          match value {
            BlockedData(_, true) | BlockedTrailers(_) => {
              request.body.finish()
              dispatch(stream_id)
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
    } else {
      self.blocked.remove(stream_id)
    }
  }
}
