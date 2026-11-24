///|
#warnings("-unnecessary_annotation")
pub(all) struct Http2ClientConfig {
  limits : @types.Limits
  max_concurrent_streams : Int32
  body_queue_capacity : Int32
  h2_receive_window_bytes : Int32
  read_size : Int32
  read_timeout_ms : Int32?
  write_timeout_ms : Int32?
  close_callback : ((Error?) -> Unit)?
}

///|
pub fn Http2ClientConfig::defaults() -> Http2ClientConfig {
  {
    limits: @types.Limits::defaults(),
    max_concurrent_streams: 100,
    body_queue_capacity: 8,
    h2_receive_window_bytes: 65535,
    read_size: 8192,
    read_timeout_ms: Some(30000),
    write_timeout_ms: Some(30000),
    close_callback: None,
  }
}

///|
priv enum H2ClientBlockedFrame {
  BlockedData(Bytes, Bool)
  BlockedTrailers(@types.HeaderMap)
}

///|
priv struct H2ClientStream {
  id : Int32
  head : @aqueue.Queue[@types.Response[Unit]]
  body : @body.BodyStream
  credit : H2ReceiveCredit
  window_signal : @cond_var.Cond
  request_method : @types.Method
  mut response_body_bytes : Int32
  mut expected_response_bytes : Int32?
  mut response_body_allowed : Bool
  mut response_started : Bool
  mut request_finished : Bool
  mut response_ended : Bool
  mut response_finished : Bool
  mut released : Bool
  mut upload : @async.Task[Unit]?
}

///|
priv struct Http2ClientState {
  config : Http2ClientConfig
  runtime : @http2.H2Connection
  encoder : @http2.HpackContext
  decoder : @http2.HpackContext
  frames : @http2.FrameDecoder
  streams : Map[Int32, H2ClientStream]
  // DATA in this backlog has already consumed HTTP/2 receive credit. Credit
  // is restored only after BodyStream consumption, keeping it byte-bounded.
  blocked : Map[Int32, @deque.Deque[H2ClientBlockedFrame]]
  state_changed : () -> Unit
  mut received_settings : Bool
  admission : @cond_var.Cond
  blocked_signal : @aqueue.Queue[Unit]
  runtime_lock : @async.Mutex
  write_lock : @async.Mutex
  read : async (Int32) -> Bytes?
  write : async (Bytes) -> Unit
  spawn : (async () -> Unit) -> @async.Task[Unit]
  mut failure : Error?
  mut draining : Bool
  mut close_notified : Bool
  mut discarded_capacity : Int32
}

///|
pub struct Http2ClientConnection {
  priv shared : Http2ClientState
}

///|
async fn[B : @body.Body] send_h2_request_body(
  shared : Http2ClientState,
  stream : H2ClientStream,
  body : B,
  expected : Int32?,
) -> Unit {
  errdefer body.cancel(@body.BodyError::Cancelled)
  errdefer shared.cancel_stream(
    stream.id,
    @http2.H2ProtocolError::StreamError(
      stream.id,
      Cancel,
      "request body producer failed",
    ),
  )
  write_h2_body(
    stream.id,
    body,
    expected,
    false,
    async fn(requested) {
      for ;; {
        if stream.request_finished || shared.failure is Some(_) {
          raise shared.closed_error()
        }
        shared.runtime_lock.acquire()
        let result = shared.runtime.reserve_send_capacity(stream.id, requested)
        shared.runtime_lock.release()
        let capacity = result.unwrap_or_error()
        if capacity > 0 {
          return capacity
        }
        stream.window_signal.wait()
      }
    },
    bytes => shared.write_bytes(bytes),
    trailers => {
      shared.write_headers(() => {
        @http2.encode_trailers(shared.encoder, stream.id, trailers)
      })
    },
  )
  shared.runtime_lock.acquire()
  let result = shared.runtime.finish_local_stream(stream.id)
  shared.runtime_lock.release()
  match result {
    Ok(_) => ()
    Err(error) => raise error
  }
  stream.request_finished = true
  shared.admission.signal()
  shared.release_stream(stream)
}

///|
async fn Http2ClientState::admit_stream(
  self : Http2ClientState,
  end_stream : Bool,
) -> Int32 {
  for ;; {
    self.runtime_lock.acquire()
    let opened = {
      defer self.runtime_lock.release()
      if self.failure is Some(error) {
        raise error
      }
      if self.draining {
        raise @http2.H2ProtocolError::ConnectionError(
          RefusedStream,
          "cannot create stream on a draining connection",
        )
      }
      if self.streams.length() >= self.config.max_concurrent_streams {
        None
      } else {
        match self.runtime.try_open_local_stream(end_stream~) {
          Ok(id) => id
          Err(error) => raise error
        }
      }
    }
    if opened is Some(id) {
      if id == 0x7fffffff {
        self.draining = true
        self.admission.broadcast()
        (self.state_changed)()
      }
      return id
    }
    // No suspension separates the capacity check from waiter registration.
    self.admission.wait()
  }
}

///|
#warnings("-unnecessary_annotation")
pub async fn[B : @body.Body] Http2ClientConnection::send(
  self : Http2ClientConnection,
  request : @types.Request[B],
) -> @types.Response[@body.BodyStream] {
  let mut upload_owned = false
  // Admission, encoding, and the first header write can all fail before an
  // upload task exists. Keep the caller's body owned across those boundaries.
  errdefer (if !upload_owned {
    request.body.cancel(@body.BodyError::Cancelled)
  })
  let hint = request.body.size_hint().exact_size()
  let exact_zero = hint == Some(0)
  let stream_id = self.shared.admit_stream(exact_zero)
  let credit = H2ReceiveCredit::new()
  let body = match
    @body.BodyStream::new(
      capacity=self.shared.config.body_queue_capacity,
      on_data_consumed=async fn(amount) {
        errdefer self.shared.cancel_stream(
          stream_id,
          @http2.H2ProtocolError::StreamError(
            stream_id,
            Cancel,
            "response body consumption callback failed",
          ),
        )
        self.shared.release_consumed_capacity(stream_id, credit, amount)
      },
      on_cancel=fn(error) {
        if credit.retired {
          return
        }
        self.shared.discard_capacity(credit.retire())
        self.shared.cancel_stream(stream_id, error)
      },
    ) {
    Ok(value) => value
    Err(error) => {
      ignore(self.shared.runtime.reset_stream(stream_id))
      self.shared.admission.signal()
      raise error
    }
  }
  let stream : H2ClientStream = {
    id: stream_id,
    head: Queue(kind=Blocking(1)),
    body,
    credit,
    window_signal: @cond_var.Cond(),
    request_method: request.http_method,
    response_body_bytes: 0,
    expected_response_bytes: None,
    response_body_allowed: true,
    response_started: false,
    request_finished: exact_zero,
    response_ended: false,
    response_finished: false,
    released: false,
    upload: None,
  }
  self.shared.streams.set(stream_id, stream)
  // Before HEADERS is handed to the writer there is no peer stream to reset.
  // A partial wire write already closes the connection in write_locked.
  let expected = {
    errdefer (if !stream.released {
      ignore(self.shared.runtime.reset_stream(stream_id))
      self.shared.fail_stream(stream, @body.BodyError::Cancelled)
    })
    let expected = h2_outgoing_length(stream_id, request.headers, hint)
    self.shared.write_headers(fn() {
      @http2.encode_request_headers(
        self.shared.encoder,
        stream_id,
        request,
        exact_zero,
      )
    })
    expected
  }
  // If the caller leaves while waiting for headers, use the same cancellation
  // path as an abandoned response body, including its asynchronous wire reset.
  errdefer body.cancel(@body.BodyError::Cancelled)
  if !exact_zero {
    let producer = async fn() {
      send_h2_request_body(self.shared, stream, request.body, expected)
    }
    upload_owned = true
    stream.upload = Some((self.shared.spawn)(producer))
  }
  let response = stream.head.get()
  response.map_body(fn(_) { body })
}

///|
/// Whether this session can admit new requests, including requests waiting for a peer slot.
pub fn Http2ClientConnection::accepts_requests(
  self : Http2ClientConnection,
) -> Bool {
  self.shared.failure is None && !self.shared.draining
}

///|
/// Both directions of every application stream have finished.
pub fn Http2ClientConnection::is_idle(self : Http2ClientConnection) -> Bool {
  self.shared.streams.is_empty()
}

///|
/// Wait for the peer's initial stream limits before issuing a burst on a new connection.
pub async fn Http2ClientConnection::wait_for_settings(
  self : Http2ClientConnection,
) -> Unit {
  while !self.shared.received_settings {
    if self.shared.failure is Some(error) {
      raise error
    }
    self.shared.admission.wait()
  }
}

///|
pub fn Http2ClientConnection::close(self : Http2ClientConnection) -> Unit {
  self.shared.close_with(None)
}

///|
pub async fn[R : @aio.BinaryReader, W : @aio.BinaryWriter, X] with_http2_client_connection(
  reader : R,
  writer : W,
  run : async (Http2ClientConnection) -> X,
  config~ : Http2ClientConfig = Http2ClientConfig::defaults(),
  on_state_change~ : () -> Unit = fn() {  },
) -> X {
  match config.validate() {
    Ok(_) => ()
    Err(error) => raise error
  }
  @async_support.with_group_result(async fn(group) {
    let shared : Http2ClientState = {
      config,
      runtime: @http2.H2Connection::new(Client, limits=config.limits),
      encoder: @http2.HpackContext::new(
        max_table_size=config.limits.max_dynamic_table_bytes,
        max_header_list_size=config.limits.max_header_bytes,
      ),
      decoder: @http2.HpackContext::new(
        max_table_size=config.limits.max_dynamic_table_bytes,
        max_header_list_size=config.limits.max_header_bytes,
      ),
      frames: @http2.FrameDecoder::new(
        max_buffer_size=config.limits.max_buffer_bytes,
      ),
      streams: Map([]),
      blocked: Map([]),
      state_changed: on_state_change,
      received_settings: false,
      admission: Cond(),
      blocked_signal: Queue(kind=Unbounded),
      runtime_lock: Mutex(),
      write_lock: Mutex(),
      read: async fn(max_len) {
        read_some_with_timeout(reader, max_len, config.read_timeout_ms)
      },
      write: async fn(bytes) {
        write_with_timeout(writer, bytes, config.write_timeout_ms)
      },
      spawn: fn(task) { group.spawn(task, allow_failure=true) },
      failure: None,
      draining: false,
      close_notified: false,
      discarded_capacity: 0,
    }
    let client : Http2ClientConnection = { shared, }
    group.add_defer(fn() { shared.close_with(None) })
    shared.write_bytes(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
    let receive_window = config.h2_receive_window_bytes
    shared.write_bytes(
      Bytes::from_array(
        @http2.encode_settings_frame(
          [
            { id: 1, value: config.limits.max_dynamic_table_bytes, },
            { id: 2, value: 0, }, // This client does not consume pushed streams.
            { id: 4, value: receive_window, },
          ],
          false,
        ),
      ),
    )
    match shared.runtime.set_local_initial_window(receive_window) {
      Ok(_) => ()
      Err(error) => raise error
    }
    if receive_window > 65535 {
      let increment = receive_window - 65535
      match shared.runtime.increase_connection_receive_window(increment) {
        Ok(_) => ()
        Err(error) => raise error
      }
      let encoded = match @http2.encode_window_update(0, increment) {
        Ok(value) => value
        Err(error) => raise error
      }
      shared.write_bytes(encoded)
    }
    let reader_task = group.spawn(
      async fn() {
        h2_client_reader_pump(shared) catch {
          error => shared.close_with(Some(error))
        }
      },
      no_wait=true,
      allow_failure=true,
    )
    group.spawn_bg(
      async fn() {
        while true {
          shared.blocked_signal.get() catch {
            _ => return
          }
          shared.release_discarded_capacity() catch {
            error => {
              shared.close_with(Some(error))
              return
            }
          }
          shared.drain_blocked()
        }
      },
      no_wait=true,
      allow_failure=true,
    )
    defer {
      // Close the connection before the task-group join. Upload producers are
      // waiting children and otherwise prevent the group defer below from
      // running when the caller returns after receiving a response.
      shared.close_with(None)
      reader_task.cancel()
    }
    run(client)
  })
}
