///|
/// A capability-bound HTTP/1.1 round tripper.  The callback owns DNS, socket,
/// proxy CONNECT and TLS setup; this type owns HTTP framing and response
/// lifetime.  Connections are closed after one exchange until a pool-aware
/// driver is explicitly supplied by the host.
pub struct Http1RoundTripper {
  connect : async (@transport.Endpoint, @transport.ConnectOptions) -> Result[
    @transport.StreamConnection,
    ClientError,
  ]
  limits : @types.Limits
  connect_options : @transport.ConnectOptions
}

///|
pub fn Http1RoundTripper::new(
  connect : async (@transport.Endpoint, @transport.ConnectOptions) -> Result[
    @transport.StreamConnection,
    ClientError,
  ],
  limits? : @types.Limits = @types.Limits::defaults(),
  connect_options? : @transport.ConnectOptions = @transport.ConnectOptions::defaults(),
) -> Result[Http1RoundTripper, ClientError] {
  match limits.validate() {
    Ok(_) => ()
    Err(_) => return Err(ClientInvalidOptions("invalid HTTP/1 limits"))
  }
  match connect_options.validate() {
    Ok(_) => ()
    Err(_) => return Err(ClientInvalidOptions("invalid connect options"))
  }
  Ok({ connect, limits, connect_options, })
}

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
) -> Result[@types.Request[Unit], ClientError] {
  let headers = match h1_client_wire_headers(request.headers, endpoint, true) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    http_method: request.http_method,
    uri: request.uri,
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
/// Translate a codec error without exposing protocol internals as transport
/// failures.
fn h1_client_codec_error(error : @http1.Http1Error) -> ClientError {
  let detail = match error {
    InvalidStartLine(_) => "invalid start line"
    InvalidHeader(_) => "invalid header"
    InvalidFraming(_) => "invalid framing"
    LimitExceeded(_) => "limit exceeded"
    UnexpectedEof(_) => "unexpected EOF"
  }
  ClientProtocol("HTTP/1 response framing error: " + detail)
}

///|
/// Send a request body according to the selected framing.
async fn h1_client_write_body(
  connection : @transport.StreamConnection,
  body : Bytes,
  framing : @http1.BodyFraming,
) -> Result[Unit, ClientError] {
  if !body.is_empty() {
    let encoded = match @http1.encode_body_data(body, framing) {
      Ok(value) => value
      Err(error) => return Err(h1_client_codec_error(error))
    }
    if !encoded.is_empty() {
      match connection.write(encoded) {
        Ok(_) => ()
        Err(error) => return Err(ClientTransport(error))
      }
    }
  }
  let end = match @http1.encode_body_end(framing) {
    Ok(value) => value
    Err(error) => return Err(h1_client_codec_error(error))
  }
  if !end.is_empty() {
    match connection.write(end) {
      Ok(_) => ()
      Err(error) => return Err(ClientTransport(error))
    }
  }
  Ok(())
}

///|
/// Collect one HTTP/1 response while preserving informational responses and
/// enforcing the configured decoded-body limit.
async fn h1_client_read_response(
  connection : @transport.StreamConnection,
  request_method : @types.Method,
  limits : @types.Limits,
) -> Result[@types.Response[Bytes], ClientError] {
  let decoder = @http1.ResponseDecoder::new(request_method, limits~)
  let mut final_head : @types.Response[Unit]? = None
  let body : Array[Byte] = []
  let mut ended = false
  let mut eof = false
  while !ended {
    let event = match decoder.next() {
      Ok(value) => value
      Err(error) => return Err(h1_client_codec_error(error))
    }
    match event {
      Some(ResponseHead(head)) =>
        // 1xx responses are complete messages of their own.  Keep 101 as the
        // terminal upgrade response, but continue past 100/102/etc.
        if head.status >= 200 || head.status == 101 {
          final_head = Some(head)
        }
      Some(ResponseData(data)) => {
        if final_head is None {
          return Err(
            ClientProtocol("HTTP/1 body arrived before final response"),
          )
        }
        if body.length() > limits.max_body_bytes ||
          data.length() > limits.max_body_bytes - body.length() {
          return Err(ClientProtocol("HTTP/1 response body exceeds limit"))
        }
        for byte in data {
          body.push(byte)
        }
      }
      Some(ResponseTrailers(trailers)) =>
        match final_head {
          Some(head) =>
            for field in trailers.fields() {
              head.headers.append(field.name, field.value)
            }
          None =>
            return Err(
              ClientProtocol("HTTP/1 trailers arrived before final response"),
            )
        }
      Some(ResponseEnd) => if final_head is Some(_) { ended = true }
      None =>
        if eof {
          decoder.finish_input()
          // The close-delimited decoder can emit its final data/end after EOF.
        } else {
          let bytes = match
            connection.read(limits.max_buffer_bytes.min(64 * 1024)) {
            Ok(Some(value)) => value
            Ok(None) => {
              eof = true
              decoder.finish_input()
              continue
            }
            Err(error) => return Err(ClientTransport(error))
          }
          if bytes.is_empty() {
            return Err(
              ClientProtocol("HTTP/1 transport returned an empty read"),
            )
          }
          match decoder.feed(bytes) {
            Ok(_) => ()
            Err(error) => return Err(h1_client_codec_error(error))
          }
        }
    }
  }
  let head = match final_head {
    Some(value) => value
    None =>
      return Err(ClientProtocol("HTTP/1 response ended without a final status"))
  }
  Ok({
    status: head.status,
    version: head.version,
    headers: head.headers,
    body: Bytes::from_array(body),
  })
}

///|
pub impl ByteRoundTripper for Http1RoundTripper with fn execute(self, request) {
  let endpoint = match ClientEndpoint::from_uri(request.uri) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let connection = match
    (self.connect)(endpoint.transport, self.connect_options) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  defer connection.close()
  let wire_request = match h1_client_wire_request(request, endpoint) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let framing = if request.body.is_empty() {
    @http1.NoBody
  } else {
    ContentLength(request.body.length())
  }
  let head = match @http1.encode_request_head(wire_request, framing) {
    Ok(value) => value
    Err(error) => return Err(h1_client_codec_error(error))
  }
  match connection.write(head) {
    Ok(_) => ()
    Err(error) => return Err(ClientTransport(error))
  }
  match h1_client_write_body(connection, request.body, framing) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  h1_client_read_response(connection, request.http_method, self.limits)
}
