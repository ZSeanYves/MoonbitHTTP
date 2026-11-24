///|
priv struct H3ServerRequest {
  incoming : H3IncomingBody
  mut task : @async.Task[Unit]?
  mut cancelled : Bool
}

///|
/// The protocol session has already verified pseudo-field ordering, Host
/// agreement and field semantics. Build the types used by application handlers.
fn h3_request(
  id : Int64,
  fields : Array[@http3.QpackField],
  body : @body.BodyStream,
) -> @types.Request[@body.BodyStream] raise {
  let headers = @types.HeaderMap::new()
  let mut meth = @types.Method::Get
  let mut path = ""
  let mut authority = ""
  for field in fields {
    match field.name {
      ":method" =>
        meth = @types.Method::parse_bytes(field.value).unwrap_or_error()
      ":authority" => authority = @utf8.decode(field.value)
      ":path" => path = @utf8.decode(field.value)
      ":scheme" | "host" => ()
      ":protocol" =>
        raise @http3.Http3Error::Http3StreamError(
          id,
          H3ConnectError,
          "extended CONNECT requires a tunnel handler",
        )
      _ =>
        if !append_regular_header(headers, field.name, field.value) {
          raise @http3.Http3Error::Http3StreamError(
            id,
            H3MessageError,
            "invalid HTTP header",
          )
        }
    }
  }
  headers.append_string("host", authority).unwrap_or_error()
  let uri = @types.Uri::parse_request_target(
    if meth == Connect {
      authority
    } else {
      path
    },
    meth,
  ).unwrap_or_error()
  { http_method: meth, uri, headers, version: Http3, body, }
}

///|
fn h3_trailers(
  id : Int64,
  fields : Array[@http3.QpackField],
) -> @types.HeaderMap raise {
  let headers = @types.HeaderMap::new()
  for field in fields {
    if !append_regular_header(headers, field.name, field.value) {
      raise @http3.Http3Error::Http3StreamError(
        id,
        H3MessageError,
        "invalid HTTP trailer",
      )
    }
  }
  headers
}

///|
async fn[B : @body.Body] Http3ConnectionIo::respond(
  self : Http3ConnectionIo,
  id : Int64,
  meth : @types.Method,
  response : @types.Response[B],
) -> Unit {
  with_outgoing_body_scope(response.body, async fn() {
    if response.status < 200 {
      raise @http3.Http3Error::Http3StreamError(
        id,
        H3MessageError,
        "handler must return a final response",
      )
    }
    if meth == Connect && response.status >= 200 && response.status < 300 {
      raise @http3.Http3Error::Http3StreamError(
        id,
        H3ConnectError,
        "a successful CONNECT requires a tunnel handler",
      )
    }
    let fields = [
      @http3.QpackField::from_strings(":status", response.status.to_string()).unwrap_or_error(),
    ]
    fields.append(h3_fields(response.headers))
    let suppressed = !@types.response_allows_body(meth, response.status)
    self.write_when_ready(fn() {
      self.session.send_headers(id, fields, fin=suppressed)
    })
    if suppressed {
      response.body.cancel(@body.BodyError::Cancelled)
    } else {
      self.write_body(id, response.body)
    }
  })
}

///|
/// Dispatch streamed requests on an authenticated server connection. Each
/// handler owns its request body until its response has finished streaming.
pub async fn[B : @body.Body] serve_http3_connection(
  io : Http3ConnectionIo,
  handler : async (@types.Request[@body.BodyStream]) -> @types.Response[B],
  on_request_error~ : (Int64, Error) -> Unit = (_, _) => (),
) -> Unit {
  io.session.defer_body_credit()
  let active : Map[Int64, H3ServerRequest] = Map([])
  let finished = @cond_var.Cond()
  // A late lower stream ID can arrive after a higher one has finished.
  let mut first_unprocessed = 0L
  @async.with_task_group(async fn(group) {
    if io.server_shutdown is Some(shutdown) {
      group.spawn_bg(
        async fn() {
          shutdown.wait()
          // If the last possible client request ID was processed, no further
          // request is possible and the next boundary cannot be encoded.
          if first_unprocessed <= @quic.QUIC_MAX_VARINT {
            io.write_when_ready(fn() {
              // Peer close can win the race with shutdown or a queue retry.
              if io.session.ended() {
                Ok(())
              } else {
                io.session.send_goaway(first_unprocessed)
              }
            })
          }
          while !active.is_empty() {
            finished.wait()
          }
          // A terminal session delivers the peer's actual close via next_events.
          if !io.session.ended() {
            group.return_immediately()
          }
        },
        no_wait=true,
      )
    }
    fn cancel(id : Int64) -> Unit {
      if active.get(id) is Some(request) {
        request.cancelled = true
        request.incoming.discard()
        if request.task is Some(task) {
          task.cancel()
        }
      }
    }
    while true {
      let actions = io.next_events()
      for action in actions {
        match action {
          Message(H3HeadersReceived(id, fields, false, false)) => {
            if !io.session.can_write(id) {
              continue
            }
            if (io.server_shutdown is Some(shutdown) && shutdown.has_started()) ||
              active.length() >= io.limits.max_concurrent_requests {
              (io.cancel_request)(id, H3RequestRejected)
              continue
            }
            first_unprocessed = first_unprocessed.max(id + 4L)
            let incoming = H3IncomingBody::new(io, id)
            let request = { incoming, task: None, cancelled: false, }
            active[id] = request
            request.task = Some(
              group.spawn(async fn() {
                defer {
                  active.remove(id)
                  incoming.discard()
                  if active.is_empty() {
                    finished.signal()
                  }
                }
                try {
                  let body = @body.BodyStream::from_pull(
                    () => incoming.read(),
                    on_cancel=fn(_) { incoming.discard() },
                  )
                  let message = h3_request(id, fields, body)
                  let status = expectation_response(message.headers, () => {
                    !incoming.finished &&
                    incoming.buffered_bytes == 0 &&
                    message.headers.content_length() != Ok(Some(0))
                  })
                  if status is Some(code) {
                    let fields = [
                      @http3.QpackField::from_strings(
                        ":status",
                        code.to_string(),
                      ).unwrap_or_error(),
                    ]
                    io.write_when_ready(() => {
                      io.session.send_headers(id, fields, fin=code == 417)
                    })
                  }
                  if status != Some(417) {
                    let response = handler(message)
                    io.respond(id, message.http_method, response)
                  }
                  if !incoming.finished {
                    io.write_when_ready(fn() { io.session.stop_reading(id) })
                  }
                } catch {
                  err => {
                    // A body reader woken by a reset may see its terminal
                    // body error before task cancellation takes effect.
                    if request.cancelled {
                      return
                    }
                    if @async.is_being_cancelled() {
                      raise err
                    }
                    // A handler or body failure terminates only its own exchange.
                    on_request_error(id, err)
                    (io.cancel_request)(id, H3InternalError)
                  }
                }
              }),
            )
          }
          Message(H3DataReceived(id, bytes)) =>
            if active.get(id) is Some({ incoming, .. }) &&
              incoming.failure is None {
              if !incoming.offer(bytes) {
                (io.cancel_request)(id, H3RequestCancelled)
                cancel(id)
              }
            } else {
              io.session.consume_body(id, bytes.length()).unwrap_or_error()
            }
          Message(H3HeadersReceived(id, fields, true, _)) =>
            if active.get(id) is Some({ incoming, .. }) &&
              incoming.failure is None {
              incoming.trailers = Some(h3_trailers(id, fields))
            }
          Message(H3MessageFinished(id)) =>
            if active.get(id) is Some({ incoming, .. }) {
              incoming.finished = true
              incoming.changed.signal()
            }
          StreamFailed(id, _)
          | Transport(StreamReset(id, _) | SendStopped(id, _)) => cancel(id)
          _ => ()
        }
      }
    }
  })
}
