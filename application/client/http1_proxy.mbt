///|
fn http1_pool_prefixed_stream(
  connection : @transport.StreamConnection,
  prefix : Bytes,
  endpoint : @types.Endpoint,
) -> @transport.StreamConnection {
  let mut offset = 0
  @transport.StreamConnection::new(
    endpoint,
    async fn(max_bytes) {
      if offset < prefix.length() {
        let end = (offset + max_bytes).min(prefix.length())
        let output = prefix[offset:end].to_owned()
        offset = end
        Ok(Some(output))
      } else {
        connection.read(max_bytes)
      }
    },
    async fn(bytes) { connection.write(bytes) },
    fn() { connection.close() },
  )
}

///|
/// Resolve and authorize the origin locally, then pin the proxy request to
/// the selected numeric address. All resolver candidates must pass policy;
/// Host and TLS SNI retain the original origin identity independently.
async fn Http1PooledRoundTripper::authorize_proxy_origin(
  self : Http1PooledRoundTripper,
  endpoint : @types.Endpoint,
) -> Result[@types.Endpoint, ClientError] {
  match self.authorize_endpoint(endpoint, Resolve) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let candidates = match self.resolve_candidates(endpoint) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut selected : @types.Endpoint? = None
  for candidate in candidates {
    match self.authorize_endpoint(candidate, Connect) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    if selected is None {
      selected = Some(candidate)
    }
  }
  let selected = match selected {
    Some(value) => value
    None => return Err(ClientProtocol("proxy origin has no authorized address"))
  }
  match self.authorize_endpoint(selected, ProxyConnect) {
    Ok(_) => Ok(selected)
    Err(error) => Err(error)
  }
}

///|
async fn http1_pool_connect_tunnel(
  connection : @transport.StreamConnection,
  target : @types.Endpoint,
  proxy_authorization : @types.HeaderValue?,
  limits : @types.Limits,
) -> Result[@transport.StreamConnection, ClientError] {
  let mut transferred = false
  defer (if !transferred { connection.close() })
  let uri = match
    @types.Uri::parse_request_target(target.authority(), Connect) {
    Ok(value) => value
    Err(error) => return Err(ClientInvalidUri(error))
  }
  let headers = @types.HeaderMap::new()
  match headers.append_string("host", target.authority()) {
    Ok(_) => ()
    Err(_) => return Err(ClientInvalidOptions("invalid CONNECT authority"))
  }
  match proxy_authorization {
    Some(value) => {
      let name = match @types.HeaderName::parse("proxy-authorization") {
        Ok(value) => value
        Err(_) =>
          return Err(ClientInvalidOptions("invalid proxy authorization name"))
      }
      headers.append(name, value)
    }
    None => ()
  }
  let request : @types.Request[Unit] = {
    http_method: Connect,
    uri,
    version: Http11,
    headers,
    body: (),
  }
  let encoded = match @http1.encode_request_head(request, NoBody) {
    Ok(value) => value
    Err(error) => return Err(h1_client_codec_error(error))
  }
  match connection.write(encoded) {
    Ok(_) => ()
    Err(error) => return Err(ClientTransport(error))
  }
  let decoder = @http1.ResponseDecoder::new(Connect, limits~)
  let mut final_received = false
  let mut eof = false
  for ;; {
    match decoder.next() {
      Err(error) => return Err(h1_client_codec_error(error))
      Ok(Some(ResponseHead(response))) =>
        if response.status >= 200 {
          if response.status >= 300 {
            return Err(
              ClientProtocol(
                "proxy CONNECT returned status " + response.status.to_string(),
              ),
            )
          }
          final_received = true
        }
      Ok(Some(ResponseEnd)) if final_received => {
        let buffered = decoder.take_buffered()
        let stream = http1_pool_prefixed_stream(connection, buffered, target)
        transferred = true
        return Ok(stream)
      }
      Ok(Some(ResponseData(_))) | Ok(Some(ResponseTrailers(_))) =>
        return Err(ClientProtocol("proxy CONNECT returned an unexpected body"))
      Ok(Some(ResponseEnd)) => ()
      Ok(None) => {
        if eof {
          return Err(
            ClientProtocol("proxy CONNECT ended before a final response"),
          )
        }
        match connection.read(limits.max_buffer_bytes.min(64 * 1024)) {
          Err(error) => return Err(ClientTransport(error))
          Ok(None) => {
            eof = true
            decoder.finish_input()
          }
          Ok(Some(bytes)) => {
            if bytes.is_empty() {
              return Err(ClientProtocol("proxy returned an empty non-EOF read"))
            }
            match decoder.feed(bytes) {
              Ok(_) => ()
              Err(error) => return Err(h1_client_codec_error(error))
            }
          }
        }
      }
    }
  } nobreak {
    Err(ClientProtocol("proxy CONNECT response loop terminated"))
  }
}

///|
fn http1_pool_proxy_authorization(
  headers : @types.HeaderMap,
) -> @types.HeaderValue? {
  headers.get_string("proxy-authorization")
}
