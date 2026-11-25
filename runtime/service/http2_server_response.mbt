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
    async fn(requested) {
      for ;; {
        let capacity = self.connection
          .reserve_send_capacity(stream_id, requested)
          .unwrap_or_error()
        if capacity > 0 {
          return capacity
        }
        if self.input_ended {
          raise @http2.H2ProtocolError::ConnectionError(
            ProtocolError,
            "HTTP/2 peer closed before granting send capacity",
          )
        }
        self.window_signal.wait()
      }
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
