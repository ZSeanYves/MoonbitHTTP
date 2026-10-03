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
  self.timeout_error(http1_pool_phase(phase), timeout)
}

///|
async fn Http1PooledRoundTripper::send_on_session(
  self : Http1PooledRoundTripper,
  session : Http1PooledSession,
  request : @types.Request[@body.FullBody],
) -> Result[@types.Response[@body.BodyStream], ClientError] {
  Ok(session.protocol.send(request)) catch {
    Http1PooledIoError(error) => Err(ClientTransport(error))
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
    error => raise error
  }
}

///|
fn Http1PooledRoundTripper::wire_request(
  self : Http1PooledRoundTripper,
  request : @types.Request[Bytes],
  endpoint : ClientEndpoint,
  proxy_target : @types.Endpoint?,
) -> Result[@types.Request[Unit], ClientError] {
  match self.proxy.mode() {
    HttpForward => h1_client_forward_request(request, endpoint, proxy_target)
    Direct | HttpsConnect => h1_client_wire_request(request, endpoint)
  }
}

///|
pub impl StreamingRoundTripper for Http1PooledRoundTripper with fn execute_stream(
  self,
  request,
) {
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
  let wire_request : @types.Request[@body.FullBody] = {
    http_method: wire_head.http_method,
    uri: wire_head.uri,
    version: wire_head.version,
    headers: wire_head.headers,
    body: @body.FullBody::new(request.body),
  }
  let response = match self.send_on_session(session, wire_request) {
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
async fn Http1PooledRoundTripper::collect_response_body(
  self : Http1PooledRoundTripper,
  body : @body.BodyStream,
) -> Result[(Bytes, @types.HeaderMap?), ClientError] {
  Ok(@body.collect(body, max_bytes=self.options.limits.max_body_bytes)) catch {
    Http1PooledIoError(error) => Err(ClientTransport(error))
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
pub impl ByteRoundTripper for Http1PooledRoundTripper with fn execute(
  self,
  request,
) {
  let response = match StreamingRoundTripper::execute_stream(self, request) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (body, trailers) = match self.collect_response_body(response.body) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match trailers {
    Some(values) =>
      for field in values.fields() {
        response.headers.append(field.name, field.value)
      }
    None => ()
  }
  Ok({
    status: response.status,
    version: response.version,
    headers: response.headers,
    body,
  })
}
