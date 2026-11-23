///|
priv struct H3ServerRequest {
  incoming : H3IncomingBody
  mut task : @async.Task[Unit]?
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
      ":method" => meth = h3_io_value(@types.Method::parse_bytes(field.value))
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
  h3_io_value(headers.append_string("host", authority))
  let uri = h3_io_value(
    @types.Uri::parse_request_target(
      if meth == Connect {
        authority
      } else {
        path
      },
      meth,
    ),
  )
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
async fn[B : @body.Body] H3ConnectionIo::respond(
  self : H3ConnectionIo,
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
    let fields = [
      h3_io_value(
        @http3.QpackField::from_strings(":status", response.status.to_string()),
      ),
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
  io : H3ConnectionIo,
  handler : async (@types.Request[@body.BodyStream]) -> @types.Response[B],
) -> Unit {
  io.session.defer_body_credit()
  let active : Map[Int64, H3ServerRequest] = Map([])
  @async.with_task_group(async fn(group) {
    fn cancel(id : Int64) -> Unit {
      if active.get(id) is Some(request) {
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
            if active.length() >= io.limits.max_concurrent_requests {
              h3_io_value(io.session.cancel(id))
              continue
            }
            let incoming = H3IncomingBody::new(io, id)
            let request = { incoming, task: None, }
            active[id] = request
            request.task = Some(
              group.spawn(async fn() {
                defer {
                  active.remove(id)
                  incoming.discard()
                }
                try {
                  let body = @body.BodyStream::from_pull(
                    () => incoming.read(),
                    on_cancel=fn(_) { incoming.discard() },
                  )
                  let message = h3_request(id, fields, body)
                  let response = handler(message)
                  io.respond(id, message.http_method, response)
                } catch {
                  err => {
                    if @async.is_being_cancelled() {
                      raise err
                    }
                    // A handler or body failure terminates only its own exchange.
                    match io.session.cancel(id) {
                      Ok(_) | Err(Http3StreamError(_, H3RequestCancelled, _)) =>
                        ()
                      Err(error) => raise error
                    }
                  }
                }
              }),
            )
          }
          Message(H3DataReceived(id, bytes)) =>
            if active.get(id) is Some({ incoming, .. }) && !incoming.discarded {
              if !incoming.offer(bytes) {
                h3_io_value(io.session.cancel(id))
                cancel(id)
              }
            } else {
              h3_io_value(io.session.consume_body(id, bytes.length()))
            }
          Message(H3HeadersReceived(id, fields, true, _)) =>
            if active.get(id) is Some({ incoming, .. }) && !incoming.discarded {
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
