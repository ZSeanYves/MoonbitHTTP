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
  let output = @types.HeaderMap::new()
  let host_name = match @types.HeaderName::parse("host") {
    Ok(value) => value
    Err(_) => return Err(ClientInvalidOptions("invalid Host header name"))
  }
  let proxy_authorization = match
    @types.HeaderName::parse("proxy-authorization") {
    Ok(value) => value
    Err(_) =>
      return Err(
        ClientInvalidOptions("invalid Proxy-Authorization header name"),
      )
  }
  for field in source.fields() {
    if field.name == host_name ||
      (!include_proxy_authorization && field.name == proxy_authorization) {
      continue
    }
    output.append(field.name, field.value)
  }
  let host_value = match
    @types.HeaderValue::from_string(endpoint.transport.authority()) {
    Ok(value) => value
    Err(_) => return Err(ClientInvalidOptions("invalid endpoint host"))
  }
  output.append(host_name, host_value)
  Ok(output)
}

///|
/// Build a direct-origin request target.
fn h1_client_wire_request(
  request : @types.Request[Bytes],
  endpoint : ClientEndpoint,
) -> Result[@types.Request[Unit], ClientError] {
  let origin = match request.uri.origin_form() {
    Ok(value) => value
    Err(error) => return Err(ClientInvalidUri(error))
  }
  let uri = match @types.Uri::parse(origin) {
    Ok(value) => value
    Err(error) => return Err(ClientInvalidUri(error))
  }
  let headers = match h1_client_wire_headers(request.headers, endpoint, false) {
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

///|
/// Build an absolute-form request for an HTTP forward proxy.
fn h1_client_forward_request(
  request : @types.Request[Bytes],
  endpoint : ClientEndpoint,
  proxy_target : @types.Endpoint?,
) -> Result[@types.Request[Unit], ClientError] {
  let headers = match h1_client_wire_headers(request.headers, endpoint, true) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let uri = match proxy_target {
    None => request.uri
    Some(target) => {
      let origin = match request.uri.origin_form() {
        Ok(value) => value
        Err(error) => return Err(ClientInvalidUri(error))
      }
      match
        @types.Uri::parse(target.scheme() + "://" + target.authority() + origin) {
        Ok(value) => value
        Err(error) => return Err(ClientInvalidUri(error))
      }
    }
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

///|
fn h1_client_codec_error(error : @http1.Http1Error) -> ClientError {
  ClientHttp1(error)
}
