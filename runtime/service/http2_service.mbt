///|
async fn[W : @aio.BinaryWriter] write_h2_frame(
  lock : @async.Mutex,
  writer : W,
  bytes : Bytes,
  timeout_ms : Int32?,
) -> Unit {
  lock.acquire()
  defer lock.release()
  write_with_timeout(writer, bytes, timeout_ms)
}

///|
async fn[W : @aio.BinaryWriter] write_h2_header_block(
  lock : @async.Mutex,
  writer : W,
  encode : () -> Result[Bytes, @http2.H2ProtocolError],
  timeout_ms : Int32?,
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
async fn[R : @aio.BinaryReader, W : @aio.BinaryWriter, B : @body.Body] serve_http2_connection_inner(
  reader : R,
  writer : W,
  service : async (@types.Request[@body.BodyStream]) -> @types.Response[B],
  config~ : ServerConfig = ServerConfig::defaults(),
  upgraded_request~ : @types.Request[@body.BodyStream]? = None,
  upgrade_settings~ : Bytes? = None,
  shutdown~ : ServerShutdown? = None,
  finish_transport~ : async () -> Unit = fn() {  },
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
  let pending : Map[Int32, H2PendingRequest] = Map([])
  // A reset can remove protocol state before cancellation finishes. Keep the
  // handler's admission slot until its task exits, independently of pending.
  let handlers : Map[Int32, H2HandlerTask] = Map([])
  // The protocol receive window bounds queued DATA bytes, including legal
  // DATA sent under the RFC default before our smaller SETTINGS is ACKed.
  let blocked : Map[Int32, @deque.Deque[H2ServerBlockedFrame]] = Map([])
  let header_block : Array[Byte] = []
  let mut header_stream = 0
  let mut header_end_stream = false
  let mut discarded_header_code : @http2.H2ErrorCode? = None
  let write_lock = @async.Mutex::Mutex()
  let control = H2ServerControl::new(connection, config.limits.max_streams)
  let window_signal = @cond_var.Cond()
  let blocked_signal : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
  let streams : H2ServerStreams = {
    input_ended: false,
    discarded_capacity: 0,
    pending,
    blocked,
    handlers,
    connection,
    control,
    write_lock,
    window_signal,
    blocked_signal,
  }
  let mut initial_settings_received = false
  let mut upgrade_dispatched = false
  let mut confirming_drain = false
  let mut drain_confirmed = false
  let drain_payload = b"draining".to_array()
  let finished = @cond_var.Cond()
  let mut last_accepted = if upgraded_request is Some(_) { 1 } else { 0 }
  @async.with_task_group(async fn(group) {
    group.add_defer(fn() {
      let error = @http2.H2ProtocolError::ConnectionError(
        Cancel,
        "HTTP/2 connection task group closed",
      )
      blocked_signal.close(error~)
      control.queue.close(error~)
      for value in pending.values() {
        value.body.fail(error)
      }
    })
    group.spawn_bg(
      async fn() {
        while true {
          let item = control.queue.get() catch { _ => return }
          write_lock.acquire()
          defer write_lock.release()
          let bytes = control.take(item)
          if !bytes.is_empty() {
            write_with_timeout(writer, bytes, config.write_timeout_ms)
          }
        }
      },
      no_wait=true,
    )
    if shutdown is Some(signal) {
      group.spawn_bg(
        async fn() {
          signal.wait()
          write_h2_frame(
            write_lock,
            writer,
            @http2.encode_goaway(last_accepted, NoError).unwrap_or_error(),
            config.write_timeout_ms,
          )
          while !handlers.is_empty() ||
                (
                  upgraded_request is Some(_) &&
                  !upgrade_dispatched &&
                  !streams.input_ended
                ) {
            finished.wait()
          }
          // Let the peer receive the last END_STREAM before closing a socket
          // which may still contain incoming flow-control frames.
          confirming_drain = true
          if last_accepted > 0 && !streams.input_ended {
            // This acknowledgement protects the last response in transit.
            // It must not hold a fully drained connection for the handler deadline.
            let linger_ms = config.h2_eof_drain_timeout_ms.min(1000)
            ignore(
              @async.with_timeout_opt(linger_ms, async fn() {
                write_h2_frame(
                  write_lock,
                  writer,
                  @http2.encode_ping(drain_payload).unwrap_or_error(),
                  config.write_timeout_ms,
                )
                while !drain_confirmed && !streams.input_ended {
                  finished.wait()
                }
              }),
            )
          }
          finish_transport()
          group.return_immediately()
        },
        no_wait=true,
      )
    }
    let dispatch = fn(stream_id : Int32) {
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
          defer {
            handlers.remove(stream_id)
            finished.broadcast()
          }
          // This cleanup runs inside the handler; it must not join itself.
          errdefer (if pending.contains(stream_id) {
            streams.reset_stream_with_error(
              stream_id,
              Cancel,
              @http2.H2ProtocolError::StreamError(
                stream_id,
                Cancel,
                "handler terminated",
              ),
            ) catch {
              _ => ()
            }
          })
          if expectation_response(request.headers, () => {
              !value.request_ended &&
              value.body_bytes == 0 &&
              value.expected_body_bytes != Some(0)
            })
            is Some(status) {
            let rejected = status == 417
            let head : @types.Response[Unit] = {
              version: Http2,
              status,
              headers: @types.HeaderMap::new(),
              body: (),
            }
            write_h2_header_block(
              write_lock,
              writer,
              () => {
                @http2.encode_response_headers(
                  encoder, stream_id, head, rejected,
                )
              },
              config.write_timeout_ms,
            )
            if rejected {
              streams.finish_response(stream_id)
              return
            }
          }
          let response = service(request)
          with_outgoing_body_scope(response.body, async fn() {
            streams.send_response(
              writer,
              encoder,
              config.write_timeout_ms,
              stream_id,
              request.http_method,
              response,
            )
          })
        }),
      )
    }
    let complete_headers = async fn(
      stream_id : Int32,
      block : Array[Byte],
      end_stream : Bool,
    ) {
      let fields = match decoder.decode(Bytes::from_array(block)) {
        Ok(value) => value
        Err(error) => raise error
      }
      if discarded_header_code is Some(code) {
        discarded_header_code = None
        streams.reset_stream(stream_id, code)
        return
      }
      if pending.get(stream_id) is Some(request) {
        if request.request_ended {
          // A request trailers block already carried END_STREAM.  A second
          // HEADERS block on the same stream is a protocol error, even if
          // the handler has not finished its response yet.
          streams.reset_stream(stream_id, ProtocolError)
          return
        }
        if !end_stream {
          streams.reset_stream(stream_id, ProtocolError)
          return
        }
        let trailers = @types.HeaderMap::new()
        for field in fields {
          if field.name.has_prefix(":") ||
            !@http_fields.Trailers.allows(field.name, field.value) ||
            !append_regular_header(trailers, field.name, field.value) {
            streams.reset_stream(stream_id, ProtocolError)
            return
          }
        }
        if !request.has_expected_length() {
          streams.reset_stream(stream_id, ProtocolError)
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
      if (shutdown is Some(signal) && signal.has_started()) ||
        pending.length() >= config.limits.max_concurrent_requests ||
        handlers.length() >= config.limits.max_concurrent_requests {
        streams.reset_stream(stream_id, RefusedStream)
        return
      }
      let (body, credit) = streams.make_body(
        config.body_queue_capacity,
        stream_id,
      )
      let request = match decode_h2_request(stream_id, fields, body~, credit~) {
        Ok(value) => value
        Err(StreamError(error_stream, code, _)) => {
          streams.reset_stream(error_stream, code)
          return
        }
        Err(error) => raise error
      }
      last_accepted = last_accepted.max(stream_id)
      pending.set(stream_id, request)
      request.request_ended = end_stream
      if end_stream && !request.has_expected_length() {
        streams.reset_stream(stream_id, ProtocolError)
        return
      }
      dispatch(stream_id)
      if end_stream {
        request.body.finish()
      }
    }
    group.spawn_bg(
      async fn() {
        while true {
          blocked_signal.get() catch {
            _ => return
          }
          let amount = streams.discarded_capacity
          streams.discarded_capacity = 0
          streams.release_discarded_data(amount)
          streams.drain_blocked(dispatch)
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
    let read_frames = async fn() {
      read_some_with_timeout(reader, config.read_size, config.read_timeout_ms) catch {
        _ if confirming_drain => None
        error => raise error
      }
    }
    while read_frames() is Some(bytes) {
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
        streams.drain_blocked(dispatch)
        if !initial_settings_received {
          require_initial_h2_settings(frame)
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
              control.credit(update)
            }
            streams.reset_stream(stream_id, code)
            []
          }
          Err(error) => raise error
        }
        if confirming_drain &&
          frame.header.typ == @http2.H2_FRAME_PING &&
          (frame.header.flags & @http2.H2_FLAGS_ACK) != 0 &&
          frame.payload == drain_payload {
          drain_confirmed = true
          finished.broadcast()
        }
        for action in actions {
          match action {
            PeerHeaderTableSize(size) => {
              write_lock.acquire()
              encoder.set_encoder_table_size(size)
              write_lock.release()
            }
            SendSettingsAck =>
              control.frame(
                Bytes::from_array(@http2.encode_settings_frame([], true)),
              )
            SendPingAck(payload) => {
              let ack = match @http2.encode_ping_ack(payload) {
                Ok(value) => value
                Err(error) => raise error
              }
              control.frame(ack)
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
                streams.release_discarded_data(flow_size)
                streams.reset_stream(stream_id, ProtocolError)
                continue
              }
              if request.request_ended {
                // DATA after request END_STREAM (including after request
                // trailers) must not be admitted to the body or its blocked
                // queue.  Return the receive credit before resetting the
                // stream so the connection cannot leak flow-control window.
                streams.release_discarded_data(flow_size)
                streams.reset_stream(stream_id, ProtocolError)
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
                streams.release_discarded_data(flow_size)
                streams.reset_stream(
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
                  control.credit(update)
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
                  control.credit(update)
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
              streams.remove_failed_stream(
                stream_id,
                @http2.H2ProtocolError::StreamError(
                  stream_id,
                  Cancel,
                  "peer reset stream",
                ),
              )
              streams.cancel_handler(stream_id)
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
          finished.broadcast()
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
    streams.input_ended = true
    finished.broadcast()
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
pub async fn[R : @aio.BinaryReader, W : @aio.BinaryWriter, B : @body.Body] serve_http2_connection(
  reader : R,
  writer : W,
  service : async (@types.Request[@body.BodyStream]) -> @types.Response[B],
  config~ : ServerConfig = ServerConfig::defaults(),
  upgraded_request~ : @types.Request[@body.BodyStream]? = None,
  upgrade_settings~ : Bytes? = None,
  shutdown~ : ServerShutdown? = None,
  finish_transport~ : async () -> Unit = fn() {  },
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
        shutdown~,
        finish_transport~,
      )
    },
    config.close_callback,
  )
}
