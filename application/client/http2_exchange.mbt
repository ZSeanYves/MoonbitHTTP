///|
fn http2_client_error(failure : Error) -> ClientError raise {
  match failure {
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
) -> Result[@types.Response[@body.BodyStream], ClientError] {
  let mut submitted = false
  defer (if !submitted { request.body.cancel(@body.BodyError::Cancelled) })
  let endpoint = match ClientEndpoint::from_uri(request.uri) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  guard self.reserve(endpoint) is Some(entry) else {
    return Err(ClientCancelled("HTTP/2 client is closed"))
  }
  defer {
    entry.users -= 1
    if entry.users == 0 {
      // No caller remains to use a connection still waiting on DNS, TLS or SETTINGS.
      if entry.state is Opening && entry.worker is Some(worker) {
        entry.retiring = true
        worker.cancel()
      }
      self.changed.broadcast()
    }
  }
  while !self.closed {
    match entry.state {
      Opening => self.changed.wait()
      Rejected(error) => return Err(error)
      Failed(error) => return Err(http2_client_error(error))
      Ready(client) => {
        let headers = client_wire_headers(
          request.headers,
          include_proxy_authorization=false,
        )
        submitted = true
        return Ok(client.send({ ..request, version: Http2, headers, })) catch {
          error => Err(http2_client_error(error))
        }
      }
    }
  }
  Err(ClientCancelled("HTTP/2 client is closed"))
}

///|
pub impl StreamingRoundTripper for Http2Client with fn execute_stream(
  self,
  request,
) {
  self.execute_body(request.map_body(fn(bytes) { @body.FullBody::new(bytes) }))
}

///|
pub impl ByteRoundTripper for Http2Client with fn execute(self, request) {
  let response = match StreamingRoundTripper::execute_stream(self, request) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok(collect_client_response(response, self.config.limits.max_body_bytes)) catch {
    error => Err(http2_client_error(error))
  }
}
