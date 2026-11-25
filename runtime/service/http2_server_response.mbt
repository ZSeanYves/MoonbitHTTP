///|
async fn[W : @aio.BinaryWriter, B : @body.Body] H2ServerStreams::send_response(
  self : H2ServerStreams,
  writer : W,
  encoder : @http2.HpackContext,
  write_timeout_ms : Int32?,
  stream_id : Int32,
  meth : @types.Method,
  response : @types.Response[B],
) -> Unit {
  if response.status < 200 {
    raise @http2.H2ProtocolError::StreamError(
      stream_id,
      ProtocolError,
      "handler must return a final response",
    )
  }
  let suppressed = meth == Head || !@types.status_allows_body(response.status)
  if meth == Connect &&
    response.status < 300 &&
    response.headers.get_string("content-length") is Some(_) {
    raise @http2.H2ProtocolError::StreamError(
      stream_id,
      ProtocolError,
      "content-length is forbidden for a successful CONNECT",
    )
  }
  let hint = if suppressed {
    None
  } else {
    response.body.size_hint().exact_size()
  }
  let expected = h2_outgoing_length(stream_id, response.headers, hint)
  let end_on_headers = suppressed || hint == Some(0)
  write_h2_header_block(
    self.write_lock,
    writer,
    fn() {
      @http2.encode_response_headers(
        encoder, stream_id, response, end_on_headers,
      )
    },
    write_timeout_ms,
  )
  if suppressed {
    self.finish_response(stream_id)
    response.body.cancel(@body.BodyError::Cancelled)
    return ()
  }
  write_h2_body(
    stream_id,
    () => response.body.next_frame(),
    expected,
    end_on_headers,
    chunk => {
      write_h2_data_chunk(
        stream_id,
        chunk,
        self.write_lock,
        requested => {
          self.connection
          .reserve_send_capacity(stream_id, requested)
          .unwrap_or_error()
        },
        async fn() {
          if self.input_ended {
            raise @http2.H2ProtocolError::ConnectionError(
              ProtocolError,
              "HTTP/2 peer closed before granting send capacity",
            )
          }
          self.window_signal.wait()
        },
        bytes => write_with_timeout(writer, bytes, write_timeout_ms),
      )
    },
    bytes => write_h2_frame(self.write_lock, writer, bytes, write_timeout_ms),
    trailers => {
      write_h2_header_block(
        self.write_lock,
        writer,
        () => @http2.encode_trailers(encoder, stream_id, trailers),
        write_timeout_ms,
      )
    },
  )
  self.finish_response(stream_id)
}

///|
fn[W : @aio.BinaryWriter, B : @body.Body] H2ServerStreams::dispatch(
  self : H2ServerStreams,
  stream_id : Int32,
  group : @async.TaskGroup,
  writer : W,
  encoder : @http2.HpackContext,
  service : async (@types.Request[@body.BodyStream]) -> @types.Response[B],
) -> Unit {
  guard self.pending.get(stream_id) is Some(value) else { return }
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
  self.handlers.set(stream_id, handler)
  handler.task = Some(
    group.spawn(async fn() {
      defer {
        self.handlers.remove(stream_id)
        self.finished.broadcast()
      }
      // This cleanup runs inside the handler; it must not join itself.
      errdefer (if self.pending.contains(stream_id) {
        self.reset_stream_with_error(
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
          self.write_lock,
          writer,
          () => {
            @http2.encode_response_headers(encoder, stream_id, head, rejected)
          },
          self.config.write_timeout_ms,
        )
        if rejected {
          self.finish_response(stream_id)
          return
        }
      }
      let response = service(request)
      with_outgoing_body_scope(response.body, async fn() {
        self.send_response(
          writer,
          encoder,
          self.config.write_timeout_ms,
          stream_id,
          request.http_method,
          response,
        )
      })
    }),
  )
}
