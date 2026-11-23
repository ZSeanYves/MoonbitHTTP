///|
pub(all) suberror H3ClientError {
  InvalidOrigin
  InvalidRequest(String)
  ClientClosed
  Goaway(Int64)
  PeerReset(Int64, Int64)
} derive(Eq, Debug)

///|
priv struct H3ClientRequest {
  incoming : H3IncomingBody
  head : @aqueue.Queue[@types.Response[@body.BodyStream]]
  mut upload : @async.Task[Unit]?
  mut upload_done : Bool
  mut consumed : Bool
}

///|
/// A single authenticated HTTP/3 origin. Each send owns one request stream.
pub struct H3Client {
  priv io : H3ConnectionIo
  priv authority : @types.Authority
  priv streams : Map[Int64, H3ClientRequest]
  priv spawn : (async () -> Unit) -> @async.Task[Unit]
  priv state_changed : () -> Unit
  priv mut terminal : Error?
}

///|
/// A peer that is closing or has sent GOAWAY cannot accept new requests.
pub fn H3Client::accepts_requests(self : H3Client) -> Bool {
  self.terminal is None &&
  self.io.session.peer_goaway() is None &&
  !self.io.session.ended()
}

///|
/// Includes responses retained by the caller and unfinished uploads.
pub fn H3Client::is_idle(self : H3Client) -> Bool {
  self.streams.is_empty()
}

///|
fn H3Client::notify_state_change(self : H3Client) -> Unit {
  self.io.write_changed.broadcast()
  (self.state_changed)()
}

///|
fn H3Client::release(self : H3Client, stream : H3ClientRequest) -> Unit {
  if stream.upload_done && stream.consumed {
    self.streams.remove(stream.incoming.id)
    self.notify_state_change()
  }
}

///|
fn H3Client::fail_request(
  self : H3Client,
  id : Int64,
  error : Error,
  reset~ : Bool,
) -> Unit {
  guard self.streams.get(id) is Some(stream) else { return }
  self.streams.remove(id)
  stream.incoming.discard(reason=error)
  stream.head.close(error~, clear=true)
  if stream.upload is Some(task) {
    task.cancel()
  }
  if reset {
    (self.io.cancel_request)(id, H3RequestCancelled)
  }
  self.notify_state_change()
}

///|
fn H3Client::stop_upload(self : H3Client, stream : H3ClientRequest) -> Unit {
  stream.upload_done = true
  if stream.upload is Some(task) {
    task.cancel()
  }
  self.release(stream)
}

///|
fn H3Client::close(
  self : H3Client,
  error : Error,
  preserve_complete~ : Bool,
) -> Unit {
  if self.terminal is None {
    self.terminal = Some(error)
  }
  for id in self.streams.keys().to_array() {
    if preserve_complete &&
      self.streams.get(id) is Some(stream) &&
      stream.incoming.finished {
      self.stop_upload(stream)
      continue
    }
    self.fail_request(id, error, reset=!preserve_complete)
  }
  self.notify_state_change()
}

///|
fn[B : @body.Body] H3Client::request_fields(
  self : H3Client,
  request : @types.Request[B],
) -> Array[@http3.QpackField] raise H3ClientError {
  let target = match
    @http_fields.request_target(request, "https", fallback=Some(self.authority)) {
    Ok(target) => target
    Err(reason) => raise InvalidRequest(reason)
  }
  if target.authority.host != self.authority.host ||
    target.authority.port.unwrap_or(443) != self.authority.port.unwrap_or(443) ||
    (target.resource is Some((scheme, _)) && scheme != "https") {
    raise InvalidOrigin
  }
  if request.body.size_hint().exact_size() == Some(0) &&
    @types.RequestExpectations::from_headers(request.headers).continue_requested {
    raise InvalidRequest("100-continue requires request content")
  }
  let fields : Array[@http3.QpackField] = target.pseudo_fields(
    request.http_method,
    (name, value) => { name, value, sensitive: false, },
  )
  for field in request.headers.fields() {
    if field.name.value != "host" && field.name.value != "proxy-authorization" {
      fields.push({
        name: field.name.value,
        value: field.value.bytes,
        sensitive: false,
      })
    }
  }
  fields
}

///|
async fn H3Client::open(
  self : H3Client,
  fields : Array[@http3.QpackField],
) -> Int64 {
  for ;; {
    if self.terminal is Some(error) {
      raise error
    }
    if self.streams.length() <
      self.io.limits.max_concurrent_requests.min(self.io.limits.max_streams) {
      match self.io.session.start_request(fields) {
        Ok(id) => return id
        Err(Http3Protocol(Http3WriteBlocked))
        | Err(Http3Transport(FlowControl(_, _))) => ()
        Err(Http3Protocol(Http3StreamError(_, H3RequestRejected, _))) if self.io.session.peer_goaway()
          is Some(first) =>
          // Transport progress can wake a sender before read() receives the event.
          raise H3ClientError::Goaway(first)
        Err(error) => raise error
      }
    }
    self.io.write_changed.wait()
  }
}

///|
/// Send once on this origin. Drain or cancel the returned body inside the
/// client scope. Requests may run concurrently and receive response headers
/// while their upload producer is still running.
pub async fn[B : @body.Body] H3Client::send(
  self : H3Client,
  request : @types.Request[B],
) -> @types.Response[@body.BodyStream] {
  let mut owned = false
  defer (if !owned { request.body.cancel(@body.BodyError::Cancelled) })
  let id = self.open(self.request_fields(request))
  let stream : H3ClientRequest = {
    incoming: H3IncomingBody::new(self.io, id),
    head: Queue(kind=Blocking(1)),
    upload: None,
    upload_done: false,
    consumed: false,
  }
  self.streams[id] = stream
  errdefer self.fail_request(id, @body.BodyError::Cancelled, reset=true)
  owned = true
  stream.upload = Some(
    (self.spawn)(async fn() {
      defer {
        stream.upload = None
        stream.upload_done = true
        self.release(stream)
      }
      with_outgoing_body_scope(request.body, async fn() {
        self.io.flush()
        self.io.write_body(id, request.body)
      }) catch {
        @http3.Http3Error::Http3StreamError(stream_id, H3RequestCancelled, _) if stream_id ==
          id &&
          !self.io.session.can_write(id) =>
          // The transport has already stopped the upload. The reader still
          // owns the response, which can finish successfully after STOP_SENDING.
          ()
        error =>
          if !stream.upload_done && !@async.is_being_cancelled() {
            stream.upload = None
            self.fail_request(id, error, reset=true)
          }
      }
    }),
  )
  stream.head.get()
}

///|
fn H3Client::response_head(
  self : H3Client,
  stream : H3ClientRequest,
  fields : Array[@http3.QpackField],
) -> Unit raise {
  let id = stream.incoming.id
  let mut status = 0
  let headers = @types.HeaderMap::new()
  for f in fields {
    if f.name == ":status" {
      status = @string.parse_int(@utf8.decode(f.value))
    } else if !append_regular_header(headers, f.name, f.value) {
      raise @http3.Http3Error::Http3StreamError(
        id,
        H3MessageError,
        "invalid response field",
      )
    }
  }
  let body = @body.BodyStream::from_pull(
    () => stream.incoming.read(),
    on_terminate=fn(error) {
      if error is None {
        stream.consumed = true
        self.release(stream)
      }
    },
    on_cancel=fn(error) { self.fail_request(id, error, reset=true) },
  )
  ignore(stream.head.try_put({ status, version: Http3, headers, body, }))
}

///|
async fn H3Client::read(self : H3Client) -> Unit {
  while true {
    for action in self.io.next_events() {
      match action {
        Message(H3HeadersReceived(id, fields, trailers, false)) =>
          if self.streams.get(id) is Some(stream) {
            if trailers {
              stream.incoming.trailers = Some(h3_trailers(id, fields))
            } else {
              self.response_head(stream, fields)
            }
          }
        Message(H3DataReceived(id, bytes)) =>
          match self.streams.get(id) {
            Some(stream) =>
              if !stream.incoming.offer(bytes) {
                self.fail_request(
                  id,
                  @http3.Http3Error::Http3LimitExceeded(
                    "HTTP/3 unread response body",
                    self.io.limits.max_buffer_bytes,
                  ),
                  reset=true,
                )
              }
            None =>
              self.io.session.consume_body(id, bytes.length()).unwrap_or_error()
          }
        Message(H3MessageFinished(id)) =>
          if self.streams.get(id) is Some(stream) {
            stream.incoming.finished = true
            stream.incoming.changed.signal()
          }
        Transport(SendStopped(id, _)) =>
          if self.streams.get(id) is Some(stream) {
            self.stop_upload(stream)
          }
        Transport(StreamReset(id, code)) =>
          self.fail_request(id, H3ClientError::PeerReset(id, code), reset=true)
        StreamFailed(id, code) =>
          self.fail_request(
            id,
            @http3.Http3Error::Http3StreamError(
              id, code, "response stream failed",
            ),
            reset=false,
          )
        Message(H3GoawayReceived(first)) => {
          self.terminal = Some(H3ClientError::Goaway(first))
          self.notify_state_change()
          for id in self.streams.keys().to_array() {
            if id >= first {
              self.fail_request(
                id,
                @http3.Http3Error::Http3StreamError(
                  id,
                  H3RequestRejected,
                  "request rejected by GOAWAY",
                ),
                reset=true,
              )
            }
          }
        }
        _ => ()
      }
    }
  }
}

///|
/// Build an HTTP client on a verified connection. By default the HTTPS
/// origin uses the authenticated hostname and the UDP peer port. Supply
/// origin_port when a different transport port serves that HTTPS origin.
pub async fn[X] with_h3_client(
  io : H3ConnectionIo,
  run : async (H3Client) -> X,
  origin_port? : Int? = None,
  on_state_change? : () -> Unit = fn() {  },
) -> X {
  guard io.authenticated_origin is Some(peer) else {
    raise H3ClientError::InvalidOrigin
  }
  let origin = match origin_port {
    None => peer
    Some(port) =>
      @types.Endpoint::new("https", peer.host, port).unwrap_or_error()
  }
  let authority = @types.Authority::parse_endpoint(origin.authority()).unwrap_or_error()
  io.session.defer_body_credit()
  @async.with_task_group(async fn(group) {
    let client : H3Client = {
      io,
      authority,
      streams: Map([]),
      terminal: None,
      state_changed: on_state_change,
      spawn: task => group.spawn(task, no_wait=true),
    }
    defer client.close(
      io.failure.unwrap_or(H3ClientError::ClientClosed),
      preserve_complete=false,
    )
    group.spawn_bg(
      async fn() {
        client.read() catch {
          error =>
            if !@async.is_being_cancelled() {
              client.close(error, preserve_complete=true)
            }
        }
      },
      no_wait=true,
    )
    run(client)
  })
}
