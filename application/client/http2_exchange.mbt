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
  self.pool.exchange(request, async fn(client, request) {
    let headers = client_wire_headers(
      request.headers,
      include_proxy_authorization=false,
    )
    client.send({ ..request, version: Http2, headers, })
  }) catch {
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
) -> Result[@types.Response[Bytes], ClientError] {
  let response = match self.execute_stream(request) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok(collect_client_response(response, self.max_body_bytes)) catch {
    error => Err(http2_client_error(error))
  }
}
