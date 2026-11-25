///|
fn http2_client_error(failure : Error) -> ClientError raise {
  match failure {
    ClientError::ClientTimeout(phase, elapsed, deadline) =>
      ClientTimeout(phase, elapsed, deadline)
    @service.StreamIoError::StreamIoError(error) => ClientTransport(error)
    @http2.H2ProtocolError::ConnectionError(code, detail) =>
      ClientHttp2(ConnectionError(code, detail))
    @http2.H2ProtocolError::StreamError(id, code, detail) =>
      ClientHttp2(StreamError(id, code, detail))
    @body.BodyLimitExceeded::BodyLimitExceeded(limit~) => ClientBodyLimit(limit)
    error => raise error
  }
}

///|
/// Send a streaming body once. Drain or cancel the response body inside the pool scope.
pub async fn[B : @body.Body] Http2Client::execute_body(
  self : Http2Client,
  request : @types.Request[B],
  timeouts? : ClientTimeouts,
) -> Result[@types.Response[@body.BodyStream], ClientError] {
  if timeouts is Some(limits) && limits.validate() is Err(error) {
    request.body.cancel(error)
    return Err(error)
  }
  let mut expansion_started : Int64? = None
  let expansion_budget = fn(ms : Int32) {
    let now = (self.now_millis)()
    let start = expansion_started.unwrap_or(now)
    expansion_started = Some(start)
    let remaining = (client_deadline(start, ms) - now)
      .clamp(min=0L, max=ms.to_int64())
      .to_int()
    (remaining, client_phase_timeout(ClientRequestHeaders, start, ms))
  }
  self.pool.exchange(
    request,
    async fn(client, request) {
      let headers = client_wire_headers(
        request.headers,
        include_proxy_authorization=false,
      )
      let timeout = phase_timeouts(
        timeouts,
        self.now_millis,
        request_headers=expansion_budget,
      )
      client.send({ ..request, version: Http2, headers, }, timeout?)
    },
    expansion_wait=async fn(wait) {
      if timeouts is Some(limits) && limits.request_headers_ms is Some(ms) {
        let (left, error) = expansion_budget(ms)
        if left <= 0 {
          raise error
        }
        @async.with_timeout(left, wait, error~)
      } else {
        wait()
      }
    },
  ) catch {
    error => Err(http2_client_error(error))
  }
}

///|
pub async fn Http2Client::execute_stream(
  self : Http2Client,
  request : @types.Request[Bytes],
) -> Result[@types.Response[@body.BodyStream], ClientError] {
  self.execute_body(request.map_body(fn(bytes) { @body.FullBody::new(bytes) }))
}

///|
pub async fn Http2Client::execute(
  self : Http2Client,
  request : @types.Request[Bytes],
) -> Result[BufferedResponse, ClientError] {
  let response = match self.execute_stream(request) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok(collect_client_response(response, self.max_body_bytes)) catch {
    error => Err(http2_client_error(error))
  }
}
