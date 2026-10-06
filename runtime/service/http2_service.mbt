///|
priv struct H2PendingRequest {
  http_method : @types.Method
  uri : @types.Uri
  headers : @types.HeaderMap
  body : @body.BodyStream
  credit : H2ReceiveCredit
  mut body_bytes : Int
  expected_body_bytes : Int?
  mut dispatched : Bool
  mut response_finished : Bool
  mut request_ended : Bool
}

///|
priv enum H2ServerBlockedFrame {
  BlockedData(Bytes, Bool)
  BlockedTrailers(@types.HeaderMap)
}

///|
priv struct H2HandlerTask {
  mut task : @async.Task[Unit]?
}

///|
fn H2PendingRequest::has_expected_length(self : H2PendingRequest) -> Bool {
  match self.expected_body_bytes {
    Some(value) => value == self.body_bytes
    None => true
  }
}

///|
fn decode_h2_request(
  stream_id : Int,
  fields : Array[@http2.HpackHeader],
  body? : @body.BodyStream = @body.BodyStream::new().unwrap(),
  credit? : H2ReceiveCredit = H2ReceiveCredit::new(),
) -> Result[H2PendingRequest, @http2.H2ProtocolError] {
  let mut meth_text = ""
  let mut path = ""
  let mut scheme = ""
  let mut authority = ""
  let mut saw_method = false
  let mut saw_path = false
  let mut saw_scheme = false
  let mut saw_authority = false
  let mut regular_host : @types.Authority? = None
  let mut saw_regular = false
  let headers = @types.HeaderMap::new()
  for field in fields {
    if field.name.has_prefix(":") {
      if saw_regular {
        return Err(
          StreamError(
            stream_id,
            ProtocolError,
            "pseudo-header follows regular header",
          ),
        )
      }
      match field.name {
        ":method" => {
          if saw_method {
            return Err(
              StreamError(stream_id, ProtocolError, "duplicate :method"),
            )
          }
          saw_method = true
          meth_text = match h2_field_text(field.value) {
            Some(value) => value
            None =>
              return Err(
                StreamError(stream_id, ProtocolError, "invalid :method"),
              )
          }
        }
        ":path" => {
          if saw_path {
            return Err(StreamError(stream_id, ProtocolError, "duplicate :path"))
          }
          saw_path = true
          path = match h2_field_text(field.value) {
            Some(value) => value
            None =>
              return Err(StreamError(stream_id, ProtocolError, "invalid :path"))
          }
        }
        ":scheme" => {
          if saw_scheme {
            return Err(
              StreamError(stream_id, ProtocolError, "duplicate :scheme"),
            )
          }
          saw_scheme = true
          scheme = match h2_field_text(field.value) {
            Some(value) => value
            None =>
              return Err(
                StreamError(stream_id, ProtocolError, "invalid :scheme"),
              )
          }
        }
        ":authority" => {
          if saw_authority {
            return Err(
              StreamError(stream_id, ProtocolError, "duplicate :authority"),
            )
          }
          saw_authority = true
          authority = match h2_field_text(field.value) {
            Some(value) => value
            None =>
              return Err(
                StreamError(stream_id, ProtocolError, "invalid :authority"),
              )
          }
        }
        _ =>
          return Err(
            StreamError(
              stream_id,
              ProtocolError,
              "unknown request pseudo-header",
            ),
          )
      }
    } else {
      saw_regular = true
      if h2_connection_specific(field.name) {
        return Err(
          StreamError(
            stream_id,
            ProtocolError,
            "connection-specific HTTP/2 header",
          ),
        )
      }
      if field.name == "te" && !h2_ascii_equal_fold(field.value, b"trailers") {
        return Err(
          StreamError(
            stream_id,
            ProtocolError,
            "HTTP/2 TE only permits trailers",
          ),
        )
      }
      if field.name == "host" {
        if regular_host is Some(_) {
          return Err(StreamError(stream_id, ProtocolError, "duplicate Host"))
        }
        let text = match h2_field_text(field.value) {
          Some(value) => value
          None =>
            return Err(StreamError(stream_id, ProtocolError, "invalid Host"))
        }
        regular_host = match @types.Authority::parse_endpoint(text) {
          Ok(value) => Some(value)
          Err(_) =>
            return Err(StreamError(stream_id, ProtocolError, "invalid Host"))
        }
        continue
      }
      if !append_h2_regular_header(headers, field) {
        return Err(
          StreamError(stream_id, ProtocolError, "invalid request header"),
        )
      }
    }
  }
  if !saw_method || meth_text == "" {
    return Err(
      StreamError(stream_id, ProtocolError, "missing required pseudo-header"),
    )
  }
  if meth_text == "CONNECT" {
    if !saw_authority || authority == "" || saw_path || saw_scheme {
      return Err(
        StreamError(stream_id, ProtocolError, "invalid CONNECT pseudo-headers"),
      )
    }
  } else if !saw_path ||
    path == "" ||
    !saw_scheme ||
    scheme == "" ||
    !saw_authority ||
    authority == "" {
    return Err(
      StreamError(
        stream_id,
        ProtocolError,
        "missing required request pseudo-header",
      ),
    )
  }
  let parsed_authority = match @types.Authority::parse_endpoint(authority) {
    Ok(value) => value
    Err(_) =>
      return Err(StreamError(stream_id, ProtocolError, "invalid :authority"))
  }
  if regular_host is Some(host) &&
    (
      host.host != parsed_authority.host ||
      host.port != parsed_authority.port ||
      host.ip_literal != parsed_authority.ip_literal
    ) {
    return Err(
      StreamError(stream_id, ProtocolError, "Host/:authority mismatch"),
    )
  }
  if meth_text != "CONNECT" && scheme != "http" && scheme != "https" {
    return Err(StreamError(stream_id, ProtocolError, "invalid :scheme"))
  }
  let http_method = match @types.Method::parse(meth_text) {
    Ok(value) => value
    Err(_) =>
      return Err(StreamError(stream_id, ProtocolError, "invalid :method"))
  }
  let uri = if http_method == Connect {
    match @types.Uri::parse_request_target(authority, http_method) {
      Ok(value) => value
      Err(_) =>
        return Err(StreamError(stream_id, ProtocolError, "invalid :authority"))
    }
  } else {
    match @types.Uri::parse_request_target(path, http_method) {
      Ok(value) if value.form == OriginForm || value.form == AsteriskForm =>
        value
      Err(_) =>
        return Err(StreamError(stream_id, ProtocolError, "invalid :path"))
      _ => return Err(StreamError(stream_id, ProtocolError, "invalid :path"))
    }
  }
  match headers.append_string("host", authority) {
    Ok(_) => ()
    Err(_) =>
      return Err(StreamError(stream_id, ProtocolError, "invalid :authority"))
  }
  let expected_body_bytes = match headers.content_length() {
    Ok(value) => value
    Err(_) =>
      return Err(
        StreamError(stream_id, ProtocolError, "invalid content-length"),
      )
  }
  Ok({
    http_method,
    uri,
    headers,
    body,
    credit,
    body_bytes: 0,
    expected_body_bytes,
    dispatched: false,
    response_finished: false,
    request_ended: false,
  })
}

///|
async fn[W : @aio.Writer] write_h2_frame(
  lock : @async.Mutex,
  writer : W,
  bytes : Bytes,
  timeout_ms : Int?,
) -> Unit {
  lock.acquire()
  defer lock.release()
  write_with_timeout(writer, bytes, timeout_ms)
}

///|
async fn[W : @aio.Writer] write_h2_header_block(
  lock : @async.Mutex,
  writer : W,
  encode : () -> Result[Bytes, @http2.H2ProtocolError],
  timeout_ms : Int?,
) -> Unit {
  lock.acquire()
  defer lock.release()
  let bytes = match encode() {
    Ok(value) => value
    Err(error) => raise error
  }
  write_with_timeout(writer, bytes, timeout_ms)
}

///|
async fn[R : @aio.Reader, W : @aio.Writer, B : @body.Body] serve_http2_connection_inner(
  reader : R,
  writer : W,
  service : async (@types.Request[@body.BodyStream]) -> @types.Response[B],
  config? : ServerConfig = ServerConfig::defaults(),
  upgraded_request? : @types.Request[@body.BodyStream]? = None,
  upgrade_settings? : Bytes? = None,
) -> Unit {
  match config.validate() {
    Ok(_) => ()
    Err(error) => raise error
  }
  let preface = read_exactly_with_timeout(reader, 24, config.read_timeout_ms)
  if preface != b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" {
    raise @http2.H2ProtocolError::ConnectionError(
      ProtocolError,
      "invalid HTTP/2 client preface",
    )
  }
  let receive_window = config.h2_receive_window_bytes
  write_with_timeout(
    writer,
    Bytes::from_array(
      @http2.encode_settings_frame(
        [
          { id: 1, value: config.limits.max_dynamic_table_bytes, },
          { id: 4, value: receive_window, },
        ],
        false,
      ),
    ),
    config.write_timeout_ms,
  )
  let connection = @http2.H2Connection::new(Server, limits=config.limits)
  match connection.set_local_initial_window(receive_window) {
    Ok(_) => ()
    Err(error) => raise error
  }
  if receive_window > 65535 {
    let increment = receive_window - 65535
    match connection.increase_connection_receive_window(increment) {
      Ok(_) => ()
      Err(error) => raise error
    }
    let encoded = match @http2.encode_window_update(0, increment) {
      Ok(value) => value
      Err(error) => raise error
    }
    write_with_timeout(writer, encoded, config.write_timeout_ms)
  }
  let frames = @http2.FrameDecoder::new(
    max_buffer_size=config.limits.max_buffer_bytes,
  )
  let decoder = @http2.HpackContext::new(
    max_table_size=config.limits.max_dynamic_table_bytes,
    max_header_list_size=config.limits.max_header_bytes,
  )
  let encoder = @http2.HpackContext::new(
    max_table_size=config.limits.max_dynamic_table_bytes,
    max_header_list_size=config.limits.max_header_bytes,
  )
  if upgrade_settings is Some(payload) {
    let actions = match connection.apply_settings_payload(payload) {
      Ok(value) => value
      Err(error) => raise error
    }
    for action in actions {
      if action is PeerHeaderTableSize(size) {
        encoder.set_encoder_table_size(size)
      }
    }
  }
  let pending : Map[Int, H2PendingRequest] = Map([])
  // A reset can remove protocol state before cancellation finishes. Keep the
  // handler's admission slot until its task exits, independently of pending.
  let handlers : Map[Int, H2HandlerTask] = Map([])
  // The protocol receive window bounds queued DATA bytes, including legal
  // DATA sent under the RFC default before our smaller SETTINGS is ACKed.
  let blocked : Map[Int, @deque.Deque[H2ServerBlockedFrame]] = Map([])
  let header_block : Array[Byte] = []
  let mut header_stream = 0
  let mut header_end_stream = false
  let mut discarded_header_code : @http2.H2ErrorCode? = None
  let write_lock = @async.Mutex::Mutex()
  let window_signal = @cond_var.Cond()
  let blocked_signal : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
  let mut initial_settings_received = false
  let mut upgrade_dispatched = false
  let mut discarded_capacity = 0
  let mut input_ended = false
  @async.with_task_group(async fn(group) {
    group.add_defer(fn() {
      let error = @http2.H2ProtocolError::ConnectionError(
        Cancel,
        "HTTP/2 connection task group closed",
      )
      blocked_signal.close(error~)
      for value in pending.values() {
        value.body.fail(error)
      }
    })
    let cancel_handler = async fn(stream_id : Int) {
      if handlers.get(stream_id) is Some(handler) && handler.task is Some(task) {
        task.cancel()
        // Cancellation is complete only after wait returns. The task's defer
        // owns slot removal; unexpected failures still propagate via the group.
        task.wait() catch {
          _ => ()
        }
      }
    }
    let release_discarded_data = async fn(amount : Int) {
      if amount <= 0 {
        return
      }
      let update = match connection.release_connection_capacity(amount) {
        Ok(value) => value
        Err(error) => raise error
      }
      if update is SendWindowUpdate(id, increment) {
        let encoded = match @http2.encode_window_update(id, increment) {
          Ok(value) => value
          Err(error) => raise error
        }
        write_h2_frame(write_lock, writer, encoded, config.write_timeout_ms)
      }
    }
    let release_consumed_data = async fn(
      stream_id : Int,
      credit : H2ReceiveCredit,
      amount : Int,
    ) {
      if amount <= 0 {
        return
      }
      // Claim body credit only after acquiring the write lock. If the body is
      // cancelled while another writer holds the lock, its on_cancel handler
      // retires the credit and this callback becomes a no-op.
      write_lock.acquire()
      defer write_lock.release()
      let claimed = credit.consume(amount)
      if claimed == 0 {
        return
      }
      let updates = match connection.release_capacity(stream_id, claimed) {
        Ok(value) => value
        Err(error) => raise error
      }
      for update in updates {
        if update is SendWindowUpdate(id, value) {
          let encoded = match @http2.encode_window_update(id, value) {
            Ok(value) => value
            Err(error) => raise error
          }
          write_with_timeout(writer, encoded, config.write_timeout_ms)
        }
      }
      blocked_signal.put(())
    }
    let reset_stream_with_error = async fn(
      stream_id : Int,
      code : @http2.H2ErrorCode,
      failure : Error,
      cancel_task : Bool,
    ) {
      let unread = match pending.get(stream_id) {
        Some(value) => {
          let amount = value.credit.retire()
          value.body.fail(failure)
          amount
        }
        None => 0
      }
      pending.remove(stream_id)
      blocked.remove(stream_id)
      ignore(connection.reset_stream(stream_id))
      release_discarded_data(unread)
      if cancel_task {
        cancel_handler(stream_id)
      }
      window_signal.broadcast()
      let encoded = match @http2.encode_rst_stream(stream_id, code) {
        Ok(value) => value
        Err(error) => raise error
      }
      write_h2_frame(write_lock, writer, encoded, config.write_timeout_ms)
    }
    let reset_stream = async fn(stream_id : Int, code : @http2.H2ErrorCode) {
      reset_stream_with_error(
        stream_id,
        code,
        @http2.H2ProtocolError::StreamError(
          stream_id, code, "HTTP/2 stream reset",
        ),
        true,
      )
    }
    let send_response = async fn(
      stream_id : Int,
      response : @types.Response[B],
    ) {
      let exact_zero = response.body.size_hint().exact_size() == Some(0)
      write_h2_header_block(
        write_lock,
        writer,
        fn() {
          @http2.encode_response_headers(
            encoder, stream_id, response, exact_zero,
          )
        },
        config.write_timeout_ms,
      )
      let mut sent_trailers = false
      while response.body.next_frame() is Some(frame) {
        match frame {
          Data(data) => {
            if sent_trailers {
              raise @http2.H2ProtocolError::StreamError(
                stream_id,
                ProtocolError,
                "response data follows trailers",
              )
            }
            let mut offset = 0
            while offset < data.length() {
              let requested = (data.length() - offset).min(
                @http2.H2_DEFAULT_MAX_FRAME_SIZE,
              )
              let mut capacity = match
                connection.reserve_send_capacity(stream_id, requested) {
                Ok(value) => value
                Err(error) => raise error
              }
              while capacity == 0 {
                if input_ended {
                  raise @http2.H2ProtocolError::ConnectionError(
                    ProtocolError,
                    "HTTP/2 peer closed before granting send capacity",
                  )
                }
                // The window check and waiter registration have no intervening
                // suspension. Broadcast wakes all eligible stream writers.
                window_signal.wait()
                capacity = match
                  connection.reserve_send_capacity(stream_id, requested) {
                  Ok(value) => value
                  Err(error) => raise error
                }
              }
              let chunk = data[offset:offset + capacity].to_owned()
              let encoded = match
                @http2.encode_data_frames(stream_id, chunk, false) {
                Ok(value) => value
                Err(error) => raise error
              }
              write_h2_frame(
                write_lock,
                writer,
                encoded,
                config.write_timeout_ms,
              )
              offset += capacity
            }
          }
          Trailers(trailers) => {
            if sent_trailers {
              raise @http2.H2ProtocolError::StreamError(
                stream_id,
                ProtocolError,
                "duplicate response trailers",
              )
            }
            sent_trailers = true
            write_h2_header_block(
              write_lock,
              writer,
              fn() { @http2.encode_trailers(encoder, stream_id, trailers) },
              config.write_timeout_ms,
            )
          }
        }
      }
      if !sent_trailers && !exact_zero {
        let encoded = match @http2.encode_data_frames(stream_id, b"", true) {
          Ok(value) => value
          Err(error) => raise error
        }
        write_h2_frame(write_lock, writer, encoded, config.write_timeout_ms)
      }
      match connection.finish_local_stream(stream_id) {
        Ok(_) => ()
        Err(error) => raise error
      }
      // A response body can consume the request body lazily (for example an
      // echo/proxy service). Only discard unread input after that body ends.
      if pending.get(stream_id) is Some(value) {
        value.response_finished = true
        let unread = value.credit.retire()
        if unread > 0 {
          // A service may finish its response without reading all of the
          // request. Reclaim that connection credit exactly once.
          value.body.cancel(@body.BodyError::Cancelled)
          blocked.remove(stream_id)
          release_discarded_data(unread)
        }
        if value.request_ended {
          pending.remove(stream_id)
          blocked.remove(stream_id)
        }
      }
    }
    let dispatch = fn(stream_id : Int) {
      guard pending.get(stream_id) is Some(value) else { return }
      if value.dispatched {
        return
      }
      value.dispatched = true
      let request : @types.Request[@body.BodyStream] = {
        http_method: value.http_method,
        uri: value.uri,
        version: Http2,
        headers: value.headers,
        body: value.body,
      }
      let handler : H2HandlerTask = { task: None, }
      handlers.set(stream_id, handler)
      handler.task = Some(
        group.spawn(async fn() {
          defer handlers.remove(stream_id)
          // This cleanup runs inside the handler; it must not join itself.
          errdefer (reset_stream_with_error(
            stream_id,
            Cancel,
            @http2.H2ProtocolError::StreamError(
              stream_id,
              Cancel,
              "handler terminated",
            ),
            false,
          ) catch {
            _ => ()
          })
          let response = service(request)
          with_outgoing_body_scope(response.body, async fn() {
            send_response(stream_id, response)
          })
        }),
      )
    }
    let make_body = fn(
      stream_id : Int,
    ) -> (@body.BodyStream, H2ReceiveCredit) raise {
      let credit = H2ReceiveCredit::new()
      let body = match
        @body.BodyStream::new(
          capacity=config.body_queue_capacity,
          on_data_consumed=async fn(amount) {
            errdefer (reset_stream_with_error(
              stream_id,
              Cancel,
              @http2.H2ProtocolError::StreamError(
                stream_id,
                Cancel,
                "request body credit release failed",
              ),
              false,
            ) catch {
              _ => ()
            })
            release_consumed_data(stream_id, credit, amount)
          },
          on_cancel=fn(_) {
            if credit.retired {
              return
            }
            discarded_capacity += credit.retire()
            blocked.remove(stream_id)
            // Cancelling request input must not cancel an early response.
            ignore(blocked_signal.try_put(()) catch { _ => false })
          },
        ) {
        Ok(value) => value
        Err(error) => raise error
      }
      (body, credit)
    }
    let complete_headers = async fn(
      stream_id : Int,
      block : Array[Byte],
      end_stream : Bool,
    ) {
      let fields = match decoder.decode(Bytes::from_array(block)) {
        Ok(value) => value
        Err(error) => raise error
      }
      if discarded_header_code is Some(code) {
        discarded_header_code = None
        reset_stream(stream_id, code)
        return
      }
      if pending.get(stream_id) is Some(request) {
        if request.request_ended {
          // A request trailers block already carried END_STREAM.  A second
          // HEADERS block on the same stream is a protocol error, even if
          // the handler has not finished its response yet.
          reset_stream(stream_id, ProtocolError)
          return
        }
        if !end_stream {
          reset_stream(stream_id, ProtocolError)
          return
        }
        let trailers = @types.HeaderMap::new()
        for field in fields {
          if field.name.has_prefix(":") ||
            h2_forbidden_trailer(field.name) ||
            !append_h2_regular_header(trailers, field) {
            reset_stream(stream_id, ProtocolError)
            return
          }
        }
        if !request.has_expected_length() {
          reset_stream(stream_id, ProtocolError)
          return
        }
        request.request_ended = true
        if !request.credit.retired {
          // Keep reading connection control frames while this stream waits
          // for its consumer. Trailers must remain behind earlier DATA.
          if blocked.get(stream_id) is Some(queue) {
            queue.push_back(BlockedTrailers(trailers))
          } else if !request.body.try_push(Trailers(trailers)) {
            blocked.set(stream_id, Deque([BlockedTrailers(trailers)]))
          }
        } else if request.response_finished {
          request.body.finish()
          pending.remove(stream_id)
          blocked.remove(stream_id)
        }
        dispatch(stream_id)
        return
      }
      if pending.length() >= config.limits.max_concurrent_requests ||
        handlers.length() >= config.limits.max_concurrent_requests {
        reset_stream(stream_id, RefusedStream)
        return
      }
      let (body, credit) = make_body(stream_id)
      let request = match decode_h2_request(stream_id, fields, body~, credit~) {
        Ok(value) => value
        Err(StreamError(error_stream, code, _)) => {
          reset_stream(error_stream, code)
          return
        }
        Err(error) => raise error
      }
      pending.set(stream_id, request)
      request.request_ended = end_stream
      if end_stream && !request.has_expected_length() {
        reset_stream(stream_id, ProtocolError)
        return
      }
      dispatch(stream_id)
      if end_stream {
        request.body.finish()
      }
    }
    let drain_blocked = fn() {
      for stream_id, queue in blocked {
        if pending.get(stream_id) is Some(request) {
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
            blocked.remove(stream_id)
          }
        } else {
          blocked.remove(stream_id)
        }
      }
    }
    group.spawn_bg(
      async fn() {
        while true {
          blocked_signal.get() catch {
            _ => return
          }
          let amount = discarded_capacity
          discarded_capacity = 0
          release_discarded_data(amount)
          drain_blocked()
        }
      },
      no_wait=true,
      allow_failure=true,
    )
    if upgraded_request is Some(request) {
      match connection.accept_upgraded_stream1() {
        Ok(_) => ()
        Err(error) => raise error
      }
      pending.set(1, {
        http_method: request.http_method,
        uri: request.uri,
        headers: request.headers,
        body: request.body,
        credit: H2ReceiveCredit::new(),
        body_bytes: 0,
        expected_body_bytes: None,
        dispatched: false,
        response_finished: false,
        request_ended: true,
      })
    }
    while read_some_with_timeout(
            reader,
            config.read_size,
            config.read_timeout_ms,
          )
          is Some(bytes) {
      match frames.feed(bytes) {
        Ok(_) => ()
        Err(error) => raise error
      }
      while true {
        let frame = match frames.next() {
          Ok(Some(value)) => value
          Ok(None) => break
          Err(error) => raise error
        }
        drain_blocked()
        if !initial_settings_received {
          if frame.header.typ != @http2.H2_FRAME_SETTINGS ||
            (frame.header.flags & @http2.H2_FLAGS_ACK) != 0 {
            raise @http2.H2ProtocolError::ConnectionError(
              ProtocolError,
              "client preface is not followed by SETTINGS",
            )
          }
          initial_settings_received = true
        }
        let actions = match connection.receive(frame) {
          Ok(value) => value
          Err(StreamError(stream_id, code, _)) => {
            let updates = match connection.release_discarded_capacity() {
              Ok(value) => value
              Err(error) => raise error
            }
            for update in updates {
              if update is SendWindowUpdate(id, amount) {
                let encoded = match @http2.encode_window_update(id, amount) {
                  Ok(value) => value
                  Err(error) => raise error
                }
                write_h2_frame(
                  write_lock,
                  writer,
                  encoded,
                  config.write_timeout_ms,
                )
              }
            }
            reset_stream(stream_id, code)
            []
          }
          Err(error) => raise error
        }
        for action in actions {
          match action {
            PeerHeaderTableSize(size) => {
              write_lock.acquire()
              encoder.set_encoder_table_size(size)
              write_lock.release()
            }
            SendSettingsAck =>
              write_h2_frame(
                write_lock,
                writer,
                Bytes::from_array(@http2.encode_settings_frame([], true)),
                config.write_timeout_ms,
              )
            SendPingAck(payload) => {
              let ack = match @http2.encode_ping_ack(payload) {
                Ok(value) => value
                Err(error) => raise error
              }
              write_h2_frame(write_lock, writer, ack, config.write_timeout_ms)
            }
            WindowAvailable(_, _) => window_signal.broadcast()
            HeadersStarted(stream_id, end_stream) => {
              discarded_header_code = None
              header_stream = stream_id
              header_end_stream = end_stream
              header_block.clear()
              let fragment = match @http2.header_fragment(frame) {
                Ok(value) => value
                Err(error) => raise error
              }
              for byte in fragment {
                header_block.push(byte)
              }
              if (frame.header.flags & @http2.H2_FLAGS_END_HEADERS) != 0 {
                complete_headers(stream_id, header_block.copy(), end_stream)
                header_stream = 0
              }
            }
            HeadersDiscarded(stream_id, end_headers, code) => {
              header_stream = stream_id
              header_end_stream = false
              discarded_header_code = Some(code)
              header_block.clear()
              let fragment = match @http2.header_fragment(frame) {
                Ok(value) => value
                Err(error) => raise error
              }
              for byte in fragment {
                header_block.push(byte)
              }
              if end_headers {
                complete_headers(stream_id, header_block.copy(), false)
                header_stream = 0
              }
            }
            HeadersContinued(stream_id, end_headers) => {
              if stream_id != header_stream {
                raise @http2.H2ProtocolError::ConnectionError(
                  ProtocolError,
                  "CONTINUATION stream changed",
                )
              }
              for byte in frame.payload {
                header_block.push(byte)
              }
              if end_headers {
                complete_headers(
                  stream_id,
                  header_block.copy(),
                  header_end_stream,
                )
                header_stream = 0
              }
            }
            DataReceived(stream_id, data, end_stream, flow_size) => {
              guard pending.get(stream_id) is Some(request) else {
                release_discarded_data(flow_size)
                reset_stream(stream_id, ProtocolError)
                continue
              }
              if request.request_ended {
                // DATA after request END_STREAM (including after request
                // trailers) must not be admitted to the body or its blocked
                // queue.  Return the receive credit before resetting the
                // stream so the connection cannot leak flow-control window.
                release_discarded_data(flow_size)
                reset_stream(stream_id, ProtocolError)
                continue
              }
              let exceeds_limit = request.body_bytes >
                config.limits.max_body_bytes ||
                data.length() >
                config.limits.max_body_bytes - request.body_bytes
              let exceeds_declared = match request.expected_body_bytes {
                Some(expected) =>
                  request.body_bytes > expected ||
                  data.length() > expected - request.body_bytes
                None => false
              }
              let next_body_bytes = if exceeds_limit {
                request.body_bytes
              } else {
                request.body_bytes + data.length()
              }
              let ends_short = !exceeds_limit &&
                end_stream &&
                request.expected_body_bytes is Some(expected) &&
                next_body_bytes != expected
              if exceeds_limit || exceeds_declared || ends_short {
                release_discarded_data(flow_size)
                reset_stream(
                  stream_id,
                  if exceeds_limit {
                    EnhanceYourCalm
                  } else {
                    ProtocolError
                  },
                )
                continue
              }
              request.body_bytes = next_body_bytes
              request.request_ended = end_stream
              if request.credit.retired {
                let updates = if flow_size == 0 {
                  []
                } else {
                  match connection.release_capacity(stream_id, flow_size) {
                    Ok(value) => value
                    Err(error) => raise error
                  }
                }
                for update in updates {
                  if update is SendWindowUpdate(id, amount) {
                    let encoded = match
                      @http2.encode_window_update(id, amount) {
                      Ok(value) => value
                      Err(error) => raise error
                    }
                    write_h2_frame(
                      write_lock,
                      writer,
                      encoded,
                      config.write_timeout_ms,
                    )
                  }
                }
                if end_stream && request.response_finished {
                  request.body.finish()
                  pending.remove(stream_id)
                  blocked.remove(stream_id)
                }
                continue
              }
              request.credit.outstanding += data.length()
              if flow_size > data.length() {
                let updates = match
                  connection.release_capacity(
                    stream_id,
                    flow_size - data.length(),
                  ) {
                  Ok(value) => value
                  Err(error) => raise error
                }
                for update in updates {
                  if update is SendWindowUpdate(id, amount) {
                    let encoded = match
                      @http2.encode_window_update(id, amount) {
                      Ok(value) => value
                      Err(error) => raise error
                    }
                    write_h2_frame(
                      write_lock,
                      writer,
                      encoded,
                      config.write_timeout_ms,
                    )
                  }
                }
              }
              if request.credit.retired {
                continue
              }
              if data.is_empty() && !end_stream {
                continue
              }
              let data = Bytes::from_array(data)
              if blocked.get(stream_id) is Some(queue) {
                queue.push_back(BlockedData(data, end_stream))
                continue
              }
              let accepted = request.body.try_push(Data(data))
              if !accepted {
                blocked.set(stream_id, Deque([BlockedData(data, end_stream)]))
              } else if end_stream {
                request.body.finish()
                dispatch(stream_id)
              }
            }
            StreamResetReceived(stream_id, _) => {
              let unread = match pending.get(stream_id) {
                Some(request) => {
                  let amount = request.credit.retire()
                  request.body.fail(
                    @http2.H2ProtocolError::StreamError(
                      stream_id,
                      Cancel,
                      "peer reset stream",
                    ),
                  )
                  amount
                }
                None => 0
              }
              pending.remove(stream_id)
              blocked.remove(stream_id)
              release_discarded_data(unread)
              cancel_handler(stream_id)
              window_signal.broadcast()
            }
            _ => ()
          }
        }
        if initial_settings_received &&
          upgraded_request is Some(_) &&
          !upgrade_dispatched {
          upgrade_dispatched = true
          dispatch(1)
        }
      }
    }
    if !initial_settings_received {
      // h2c may already own an outer application task even though stream 1
      // was never dispatched here. Propagate incomplete-preface EOF so that
      // the outer upgrade scope cancels and joins that task as well.
      raise @http2.H2ProtocolError::ConnectionError(
        ProtocolError,
        "HTTP/2 peer closed before initial SETTINGS",
      )
    }
    // EOF makes further WINDOW_UPDATE impossible. Responses with available
    // credit may still finish after a read-side close, but no sender may wait.
    input_ended = true
    window_signal.broadcast()
    for value in pending.values() {
      value.body.fail(
        @http2.H2ProtocolError::ConnectionError(
          ProtocolError,
          "HTTP/2 peer closed connection",
        ),
      )
    }
    // Allow finite responses after a read half-close, but bound the whole
    // remaining lifetime (handler, body producer, and writer). A failing
    // background timer cancels and joins the group, and also propagates out
    // through h2c so its outer service task cannot remain stranded.
    group.spawn_bg(
      async fn() {
        @async.sleep(config.h2_eof_drain_timeout_ms)
        raise @http2.H2ProtocolError::ConnectionError(
          Cancel,
          "HTTP/2 peer EOF drain deadline exceeded",
        )
      },
      no_wait=true,
    )
  })
}

///|
pub async fn[R : @aio.Reader, W : @aio.Writer, B : @body.Body] serve_http2_connection(
  reader : R,
  writer : W,
  service : async (@types.Request[@body.BodyStream]) -> @types.Response[B],
  config? : ServerConfig = ServerConfig::defaults(),
  upgraded_request? : @types.Request[@body.BodyStream]? = None,
  upgrade_settings? : Bytes? = None,
) -> Unit {
  run_connection_scope(
    () => {
      serve_http2_connection_inner(
        reader,
        writer,
        service,
        config=config.without_close_callback(),
        upgraded_request~,
        upgrade_settings~,
      )
    },
    config.close_callback,
  )
}
