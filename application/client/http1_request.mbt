///|
/// Builds HTTP/1 headers from trusted URI routing state. `Host` is always
/// replaced so a caller-supplied value cannot route differently from the
/// connection target. Proxy credentials are retained only on forward-proxy
/// requests and never reach a direct origin or a CONNECT tunnel.
fn h1_client_wire_headers(
  source : @types.HeaderMap,
  endpoint : ClientEndpoint,
  include_proxy_authorization : Bool,
) -> Result[@types.HeaderMap, ClientError] {
  let output = client_wire_headers(source, include_proxy_authorization~)
  match output.append_string("host", endpoint.transport.authority()) {
    Ok(_) => Ok(output)
    Err(_) => Err(ClientInvalidOptions("invalid endpoint host"))
  }
}

///|
fn[B] Http1PooledRoundTripper::wire_request(
  self : Http1PooledRoundTripper,
  request : @types.Request[B],
  endpoint : ClientEndpoint,
  proxy_target : @types.Endpoint?,
) -> Result[@types.Request[Unit], ClientError] {
  let forward = self.proxy.mode() == HttpForward
  let uri = if forward && proxy_target is None {
    request.uri
  } else {
    let path = match request.uri.origin_form() {
      Ok(value) => value
      Err(error) => return Err(ClientInvalidUri(error))
    }
    let target = match (forward, proxy_target) {
      (true, Some(proxy)) => proxy.scheme() + "://" + proxy.authority() + path
      _ => path
    }
    match @types.Uri::parse(target) {
      Ok(value) => value
      Err(error) => return Err(ClientInvalidUri(error))
    }
  }
  let headers = match
    h1_client_wire_headers(request.headers, endpoint, forward) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    http_method: request.http_method,
    uri,
    version: if request.version == Http10 {
      Http10
    } else {
      Http11
    },
    headers,
    body: (),
  })
}
