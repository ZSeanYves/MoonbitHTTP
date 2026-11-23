///|
fn http1_pool_phase(phase : @service.ClientConnectionPhase) -> ClientPhase {
  match phase {
    RequestHeaders => ClientRequestHeaders
    RequestBody => ClientRequestBody
    ResponseHeaders => ClientResponseHeaders
    ResponseBody => ClientResponseBody
  }
}

///|
fn Http1PooledRoundTripper::phase_timeout(
  self : Http1PooledRoundTripper,
  phase : @service.ClientConnectionPhase,
) -> ClientError {
  let timeout = (match phase {
    RequestHeaders => self.options.timeouts.request_headers_ms
    RequestBody => self.options.timeouts.request_body_ms
    ResponseHeaders => self.options.timeouts.response_headers_ms
    ResponseBody => self.options.timeouts.response_body_ms
  }).unwrap_or(0)
  self.dialer.timeout_error(http1_pool_phase(phase), timeout)
}

///|
async fn[T] Http1PooledRoundTripper::exchange_result(
  self : Http1PooledRoundTripper,
  run : async () -> T,
) -> Result[T, ClientError] {
  Ok(run()) catch {
    ClientStreamError(error) => Err(ClientTransport(error))
    @service.ClientConnectionError::ConnectionClosed =>
      Err(ClientConnection(ConnectionClosed))
    @service.ClientConnectionError::RequestInProgress =>
      Err(ClientConnection(RequestInProgress))
    @service.ClientConnectionTimeout::ClientConnectionTimeout(phase) =>
      Err(self.phase_timeout(phase))
    @http1.Http1Error::InvalidStartLine(detail) =>
      Err(ClientHttp1(InvalidStartLine(detail)))
    @http1.Http1Error::InvalidHeader(detail) =>
      Err(ClientHttp1(InvalidHeader(detail)))
    @http1.Http1Error::InvalidFraming(detail) =>
      Err(ClientHttp1(InvalidFraming(detail)))
    @http1.Http1Error::LimitExceeded(detail) =>
      Err(ClientHttp1(LimitExceeded(detail)))
    @http1.Http1Error::UnexpectedEof(detail) =>
      Err(ClientHttp1(UnexpectedEof(detail)))
    @body.BodyLimitExceeded::BodyLimitExceeded(limit~) =>
      Err(ClientBodyLimit(limit))
    error => raise error
  }
}

///|
pub impl StreamingRoundTripper for Http1PooledRoundTripper with fn execute_stream(
  self,
  request,
) {
  self.execute_body(request.map_body(fn(bytes) { @body.FullBody::new(bytes) }))
}

///|
/// Perform one HTTP/1 exchange over the pool. The request body is consumed
/// once, including trailers for chunked uploads. Drain or cancel the returned
/// response body to release its lease.
pub async fn[B : @body.Body] Http1PooledRoundTripper::execute_body(
  self : Http1PooledRoundTripper,
  request : @types.Request[B],
) -> Result[@types.Response[@body.BodyStream], ClientError] {
  // Until the protocol starts the upload, we own cancellation of the producer,
  // including cancellation while waiting for a slot, DNS, TCP or TLS.
  let mut upload_started = false
  defer (if !upload_started { request.body.cancel(@body.BodyError::Cancelled) })
  if self.closed {
    return Err(ClientCancelled("HTTP/1 executor is closed"))
  }
  let endpoint = match ClientEndpoint::from_uri(request.uri) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let proxy_authorization = http1_pool_proxy_authorization(request.headers)
  if self.proxy.mode() != Direct &&
    proxy_authorization is Some(_) &&
    self.proxy.identity_key() is None {
    return Err(
      ClientInvalidOptions(
        "proxy credentials require a non-secret pool identity key",
      ),
    )
  }
  let key = self.connection_key(endpoint)
  let (lease, session) = match
    self.acquire_session(key, endpoint, proxy_authorization) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut handed_off = false
  defer (if !handed_off { self.finish_lease(lease, session, false) })
  let wire_head = match
    self.wire_request(request, endpoint, session.proxy_target()) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let wire_request = wire_head.map_body(fn(_) { request.body })
  upload_started = true
  let response = match
    self.exchange_result(async fn() { session.protocol.send(wire_request) }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let inner = response.body
  let outer = @body.BodyStream::from_pull(
    async fn() { inner.next_frame() },
    size_hint=inner.size_hint(),
    on_terminate=fn(error) {
      match error {
        Some(cause) => inner.cancel(cause)
        None => ()
      }
      self.finish_lease(lease, session, error is None)
    },
  )
  handed_off = true
  Ok(response.map_body(fn(_) { outer }))
}

///|
pub impl ByteRoundTripper for Http1PooledRoundTripper with fn execute(
  self,
  request,
) {
  let response = match StreamingRoundTripper::execute_stream(self, request) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  self.exchange_result(async fn() {
    collect_client_response(response, self.options.limits.max_body_bytes)
  })
}
