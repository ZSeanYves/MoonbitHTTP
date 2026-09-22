///|
priv suberror Http1PooledIoError {
  Http1PooledIoError(@transport.TransportError)
} derive(Debug)

///|
#warnings("-alert_internal")
priv struct Http1StreamIo {
  reader_buffer : @aio.ReaderBuffer
  connection : @transport.StreamConnection
}

///|
#warnings("-alert_internal")
fn Http1StreamIo::new(
  connection : @transport.StreamConnection,
) -> Http1StreamIo {
  { reader_buffer: @aio.ReaderBuffer::new(), connection, }
}

///|
#warnings("-alert_internal")
impl @aio.Reader for Http1StreamIo with fn _get_internal_buffer(self) {
  self.reader_buffer
}

///|
#warnings("-alert_internal")
impl @aio.Reader for Http1StreamIo with fn _direct_read(
  self,
  destination,
  offset~,
  max_len~,
) {
  match self.connection.read(max_len) {
    Err(error) => raise Http1PooledIoError(error)
    Ok(None) => 0
    Ok(Some(bytes)) => {
      if bytes.is_empty() {
        raise Http1PooledIoError(
          Failed(Receive, "stream returned an empty non-EOF read"),
        )
      }
      for index in 0..<bytes.length() {
        destination[offset + index] = bytes[index]
      }
      bytes.length()
    }
  }
}

///|
#warnings("-alert_internal")
impl @aio.Writer for Http1StreamIo with fn write_once(
  self,
  source,
  offset~,
  len~,
) {
  let bytes = source[offset:offset + len].to_owned()
  match self.connection.write(bytes) {
    Ok(_) => len
    Err(error) => raise Http1PooledIoError(error)
  }
}

///|
priv struct Http1PooledSession {
  connection : @transport.StreamConnection
  protocol : @service.ClientConnection[Http1StreamIo, Http1StreamIo]
}

///|
fn Http1PooledSession::new(
  connection : @transport.StreamConnection,
  options : RequestOptions,
) -> Result[Http1PooledSession, ClientError] {
  let io = Http1StreamIo::new(connection)
  let protocol = match
    @service.ClientConnection::try_new_with_phase_timeouts(
      io,
      io,
      limits=options.limits,
      read_size=options.limits.max_buffer_bytes.min(8192),
      request_headers_timeout_ms=options.timeouts.request_headers_ms,
      request_body_timeout_ms=options.timeouts.request_body_ms,
      response_headers_timeout_ms=options.timeouts.response_headers_ms,
      response_body_timeout_ms=options.timeouts.response_body_ms,
    ) {
    Ok(value) => value
    Err(_) => {
      connection.close()
      return Err(ClientInvalidOptions("invalid HTTP/1 session configuration"))
    }
  }
  Ok({ connection, protocol, })
}

///|
fn Http1PooledSession::close(self : Http1PooledSession) -> Unit {
  self.protocol.close()
  self.connection.close()
}

///|
fn Http1PooledSession::is_reusable(self : Http1PooledSession) -> Bool {
  self.protocol.is_reusable() && !self.connection.is_closed()
}

///|
/// A capability-injected HTTP/1 executor with a bounded real-connection pool.
/// The executor is safe for concurrent async tasks: all pool mutations are
/// synchronous, while the capacity semaphore is the only waiting point.
pub struct Http1PooledRoundTripper {
  priv connect : async (@transport.Endpoint, @transport.ConnectOptions) -> Result[
    @transport.StreamConnection,
    @transport.TransportError,
  ]
  priv tls_handshake : async (@transport.StreamConnection, @tls.TlsOptions) -> Result[
    @tls.SecureConnection,
    @tls.TlsError,
  ]
  priv resolve : (async (String, @transport.ResolveOptions) -> Result[
    Array[@transport.IpAddress],
    @transport.TransportError,
  ])?
  priv authorize : (@transport.Endpoint, @transport.PolicyOperation) -> Result[
    Unit,
    @transport.PolicyError,
  ]
  priv now_millis : () -> Int64
  priv options : RequestOptions
  priv proxy : ProxyConfig
  priv origin_tls : @tls.TlsOptions
  priv proxy_tls : @tls.TlsOptions
  priv origin_tls_identity : String
  priv proxy_tls_identity : String
  priv connect_options : @transport.ConnectOptions
  priv resolve_options : @transport.ResolveOptions
  priv pool : ConnectionPool
  priv slots : @async.Semaphore
  priv sessions : Map[Int, Http1PooledSession]
  priv mut closed : Bool
}

///|
pub fn Http1PooledRoundTripper::new(
  connect : async (@transport.Endpoint, @transport.ConnectOptions) -> Result[
    @transport.StreamConnection,
    @transport.TransportError,
  ],
  tls_handshake : async (@transport.StreamConnection, @tls.TlsOptions) -> Result[
    @tls.SecureConnection,
    @tls.TlsError,
  ],
  resolve? : (async (String, @transport.ResolveOptions) -> Result[
    Array[@transport.IpAddress],
    @transport.TransportError,
  ])? = None,
  authorize? : (@transport.Endpoint, @transport.PolicyOperation) -> Result[
    Unit,
    @transport.PolicyError,
  ] = fn(_, _) { Ok(()) },
  now_millis? : () -> Int64 = fn() { 0L },
  options? : RequestOptions = RequestOptions::defaults(),
  proxy? : ProxyConfig = ProxyConfig::direct(),
  origin_tls? : @tls.TlsOptions = http1_tls_defaults(),
  proxy_tls? : @tls.TlsOptions = http1_tls_defaults(),
  origin_tls_identity? : String = "origin-tls",
  proxy_tls_identity? : String = "proxy-tls",
  connect_options? : @transport.ConnectOptions = @transport.ConnectOptions::defaults(),
  resolve_options? : @transport.ResolveOptions = @transport.ResolveOptions::defaults(),
  pool_limits? : PoolLimits = PoolLimits::defaults(),
) -> Result[Http1PooledRoundTripper, ClientError] {
  match options.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match proxy.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match origin_tls.validate_common() {
    Ok(_) => ()
    Err(_) => return Err(ClientInvalidOptions("invalid origin TLS options"))
  }
  match proxy_tls.validate_common() {
    Ok(_) => ()
    Err(_) => return Err(ClientInvalidOptions("invalid proxy TLS options"))
  }
  if origin_tls_identity.is_empty() || proxy_tls_identity.is_empty() {
    return Err(ClientInvalidOptions("TLS pool identities must not be empty"))
  }
  let connect_options = {
    ..connect_options,
    timeout_ms: options.timeouts.connect_ms,
    idle_timeout_ms: options.timeouts.idle_ms,
  }
  match connect_options.validate() {
    Ok(_) => ()
    Err(_) => return Err(ClientInvalidOptions("invalid connect options"))
  }
  let resolve_options = {
    ..resolve_options,
    timeout_ms: options.timeouts.resolve_ms,
  }
  match resolve_options.validate() {
    Ok(_) => ()
    Err(_) => return Err(ClientInvalidOptions("invalid resolve options"))
  }
  let pool = match ConnectionPool::new(limits=pool_limits) {
    Ok(value) => value
    Err(_) => return Err(ClientInvalidOptions("invalid connection pool limits"))
  }
  Ok({
    connect,
    tls_handshake,
    resolve,
    authorize,
    now_millis,
    options,
    proxy,
    origin_tls,
    proxy_tls,
    origin_tls_identity,
    proxy_tls_identity,
    connect_options,
    resolve_options,
    pool,
    slots: Semaphore(pool_limits.max_total),
    sessions: Map([]),
    closed: false,
  })
}

///|
/// Creates the executor from the repository's transport, TLS, and policy
/// capability traits without exposing their concrete types in the pool.
pub fn[
  C : @transport.StreamConnector,
  T : @tls.TlsProvider,
  P : @transport.NetworkPolicy,
] Http1PooledRoundTripper::from_capabilities(
  connector : C,
  tls_provider : T,
  policy : P,
  now_millis? : () -> Int64 = fn() { 0L },
  options? : RequestOptions = RequestOptions::defaults(),
  proxy? : ProxyConfig = ProxyConfig::direct(),
  origin_tls? : @tls.TlsOptions = http1_tls_defaults(),
  proxy_tls? : @tls.TlsOptions = http1_tls_defaults(),
  origin_tls_identity? : String = "origin-tls",
  proxy_tls_identity? : String = "proxy-tls",
  connect_options? : @transport.ConnectOptions = @transport.ConnectOptions::defaults(),
  pool_limits? : PoolLimits = PoolLimits::defaults(),
) -> Result[Http1PooledRoundTripper, ClientError] {
  Http1PooledRoundTripper::new(
    async fn(endpoint, connect_options) {
      @transport.StreamConnector::connect(connector, endpoint, connect_options)
    },
    async fn(connection, tls_options) {
      @tls.TlsProvider::client_handshake(tls_provider, connection, tls_options)
    },
    authorize=fn(endpoint, operation) {
      @transport.NetworkPolicy::authorize(policy, endpoint, operation)
    },
    now_millis~,
    options~,
    proxy~,
    origin_tls~,
    proxy_tls~,
    origin_tls_identity~,
    proxy_tls_identity~,
    connect_options~,
    pool_limits~,
  )
}

///|
/// Creates an executor that resolves hostnames explicitly and rechecks each
/// numeric address against the network policy before opening a socket.
pub fn[
  C : @transport.StreamConnector,
  R : @transport.NameResolver,
  T : @tls.TlsProvider,
  P : @transport.NetworkPolicy,
] Http1PooledRoundTripper::from_capabilities_with_resolver(
  connector : C,
  resolver : R,
  tls_provider : T,
  policy : P,
  now_millis? : () -> Int64 = fn() { 0L },
  options? : RequestOptions = RequestOptions::defaults(),
  proxy? : ProxyConfig = ProxyConfig::direct(),
  origin_tls? : @tls.TlsOptions = http1_tls_defaults(),
  proxy_tls? : @tls.TlsOptions = http1_tls_defaults(),
  origin_tls_identity? : String = "origin-tls",
  proxy_tls_identity? : String = "proxy-tls",
  connect_options? : @transport.ConnectOptions = @transport.ConnectOptions::defaults(),
  resolve_options? : @transport.ResolveOptions = @transport.ResolveOptions::defaults(),
  pool_limits? : PoolLimits = PoolLimits::defaults(),
) -> Result[Http1PooledRoundTripper, ClientError] {
  Http1PooledRoundTripper::new(
    async fn(endpoint, connect_options) {
      @transport.StreamConnector::connect(connector, endpoint, connect_options)
    },
    async fn(connection, tls_options) {
      @tls.TlsProvider::client_handshake(tls_provider, connection, tls_options)
    },
    resolve=Some(async fn(host, options) {
      @transport.NameResolver::resolve(resolver, host, options)
    }),
    authorize=fn(endpoint, operation) {
      @transport.NetworkPolicy::authorize(policy, endpoint, operation)
    },
    now_millis~,
    options~,
    proxy~,
    origin_tls~,
    proxy_tls~,
    origin_tls_identity~,
    proxy_tls_identity~,
    connect_options~,
    resolve_options~,
    pool_limits~,
  )
}

///|
fn http1_pool_deadline(start : Int64, timeout_ms : Int) -> Int64 {
  let timeout = timeout_ms.to_int64()
  if start < 0L {
    timeout
  } else if start > @int64.MAX_VALUE - timeout {
    @int64.MAX_VALUE
  } else {
    start + timeout
  }
}

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
fn Http1PooledRoundTripper::timeout_error(
  self : Http1PooledRoundTripper,
  phase : ClientPhase,
  timeout_ms : Int,
) -> ClientError {
  let start = (self.now_millis)().max(0L)
  ClientTimeout(
    phase,
    timeout_ms.to_int64(),
    http1_pool_deadline(start, timeout_ms),
  )
}

///|
fn http1_pool_stream_from_secure(
  secure : @tls.SecureConnection,
  endpoint : @transport.Endpoint,
) -> @transport.StreamConnection {
  @transport.StreamConnection::new(
    endpoint,
    async fn(max_bytes) { secure.read(max_bytes) },
    async fn(bytes) { secure.write(bytes) },
    fn() { secure.close() },
  )
}

///|
fn http1_pool_prefixed_stream(
  connection : @transport.StreamConnection,
  prefix : Bytes,
  endpoint : @transport.Endpoint,
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
async fn Http1PooledRoundTripper::secure_stream(
  self : Http1PooledRoundTripper,
  connection : @transport.StreamConnection,
  endpoint : @transport.Endpoint,
  configured : @tls.TlsOptions,
) -> Result[@transport.StreamConnection, ClientError] {
  let mut transferred = false
  defer (if !transferred { connection.close() })
  let options : @tls.TlsOptions = {
    ..configured.for_server_name(endpoint.host()),
    alpn: ["http/1.1"],
  }
  match options.validate_client() {
    Ok(_) => ()
    Err(_) => {
      connection.close()
      return Err(ClientInvalidOptions("invalid endpoint TLS options"))
    }
  }
  let started = (self.now_millis)().max(0L)
  let result = match self.options.timeouts.tls_ms {
    Some(timeout) =>
      @async.with_timeout(timeout, async fn() {
        (self.tls_handshake)(connection, options)
      }) catch {
        @async.TimeoutError => {
          connection.close()
          return Err(
            ClientTimeout(
              ClientTlsHandshake,
              timeout.to_int64(),
              http1_pool_deadline(started, timeout),
            ),
          )
        }
        error => raise error
      }
    None => (self.tls_handshake)(connection, options)
  }
  let secure = match result {
    Ok(value) => value
    Err(error) => return Err(ClientTls(error))
  }
  if options.verify_peer && !secure.is_authenticated() {
    secure.close()
    return Err(
      ClientTls(VerificationFailed("TLS provider did not authenticate peer")),
    )
  }
  match secure.alpn() {
    None | Some("http/1.1") => ()
    Some(_) => {
      secure.close()
      return Err(ClientProtocol("TLS selected a non-HTTP/1 ALPN protocol"))
    }
  }
  let stream = http1_pool_stream_from_secure(secure, endpoint)
  transferred = true
  Ok(stream)
}

///|
fn Http1PooledRoundTripper::authorize_endpoint(
  self : Http1PooledRoundTripper,
  endpoint : @transport.Endpoint,
  operation : @transport.PolicyOperation,
) -> Result[Unit, ClientError] {
  match (self.authorize)(endpoint, operation) {
    Ok(_) => Ok(())
    Err(error) => Err(ClientPolicy(error))
  }
}

///|
async fn Http1PooledRoundTripper::resolve_candidates(
  self : Http1PooledRoundTripper,
  endpoint : @transport.Endpoint,
) -> Result[Array[@transport.Endpoint], ClientError] {
  if @transport.IpAddress::parse(endpoint.host()) is Ok(_) {
    return Ok([endpoint])
  }
  let resolve = match self.resolve {
    Some(value) => value
    None => return Ok([endpoint])
  }
  let started = (self.now_millis)().max(0L)
  let result = match self.resolve_options.timeout_ms {
    Some(timeout) =>
      @async.with_timeout(timeout, async fn() {
        resolve(endpoint.host(), self.resolve_options)
      }) catch {
        @async.TimeoutError =>
          return Err(
            ClientTimeout(
              ClientResolve,
              timeout.to_int64(),
              http1_pool_deadline(started, timeout),
            ),
          )
        error => raise error
      }
    None => resolve(endpoint.host(), self.resolve_options)
  }
  let addresses = match result {
    Ok(value) => value
    Err(Timeout(Resolve)) => {
      let timeout = self.options.timeouts.resolve_ms.unwrap_or(0)
      return Err(
        ClientTimeout(
          ClientResolve,
          timeout.to_int64(),
          http1_pool_deadline(started, timeout),
        ),
      )
    }
    Err(error) => return Err(ClientTransport(error))
  }
  if addresses.is_empty() {
    return Err(
      ClientTransport(Failed(Resolve, "resolver returned no addresses")),
    )
  }
  let candidates : Array[@transport.Endpoint] = []
  let count = addresses.length().min(self.resolve_options.max_results)
  for index in 0..<count {
    let address = match @transport.IpAddress::parse(addresses[index].value()) {
      Ok(value) => value
      Err(_) =>
        return Err(
          ClientTransport(
            Failed(Resolve, "resolver returned a non-numeric address"),
          ),
        )
    }
    let candidate = match
      @transport.Endpoint::new(
        endpoint.scheme(),
        address.value(),
        endpoint.port(),
      ) {
      Ok(value) => value
      Err(error) => return Err(ClientTransport(InvalidEndpoint(error)))
    }
    if !candidates.contains(candidate) {
      candidates.push(candidate)
    }
  }
  if candidates.is_empty() {
    Err(
      ClientTransport(Failed(Resolve, "resolver returned no usable addresses")),
    )
  } else {
    Ok(candidates)
  }
}

///|
async fn Http1PooledRoundTripper::connect_candidate(
  self : Http1PooledRoundTripper,
  endpoint : @transport.Endpoint,
) -> Result[@transport.StreamConnection, ClientError] {
  let started = (self.now_millis)().max(0L)
  let result = match self.options.timeouts.connect_ms {
    Some(timeout) =>
      @async.with_timeout(timeout, async fn() {
        (self.connect)(endpoint, self.connect_options)
      }) catch {
        @async.TimeoutError =>
          return Err(
            ClientTimeout(
              ClientConnect,
              timeout.to_int64(),
              http1_pool_deadline(started, timeout),
            ),
          )
        error => raise error
      }
    None => (self.connect)(endpoint, self.connect_options)
  }
  match result {
    Ok(connection) =>
      if connection.endpoint() != endpoint {
        connection.close()
        Err(
          ClientTransport(
            Failed(Connect, "connector returned a different endpoint"),
          ),
        )
      } else {
        Ok(connection)
      }
    Err(Timeout(Connect)) => {
      let timeout = self.options.timeouts.connect_ms.unwrap_or(0)
      Err(
        ClientTimeout(
          ClientConnect,
          timeout.to_int64(),
          http1_pool_deadline(started, timeout),
        ),
      )
    }
    Err(error) => Err(ClientTransport(error))
  }
}

///|
async fn Http1PooledRoundTripper::connect_stream(
  self : Http1PooledRoundTripper,
  endpoint : @transport.Endpoint,
) -> Result[@transport.StreamConnection, ClientError] {
  let candidates = match self.resolve_candidates(endpoint) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut first_policy_error : ClientError? = None
  let mut last_connect_error : ClientError? = None
  for candidate in candidates {
    match self.authorize_endpoint(candidate, Connect) {
      Err(error) =>
        if first_policy_error is None {
          first_policy_error = Some(error)
        }
      Ok(_) =>
        match self.connect_candidate(candidate) {
          Ok(connection) => return Ok(connection)
          Err(error) => last_connect_error = Some(error)
        }
    }
  }
  match last_connect_error {
    Some(error) => Err(error)
    None =>
      match first_policy_error {
        Some(error) => Err(error)
        None =>
          Err(ClientTransport(Failed(Connect, "no connection candidates")))
      }
  }
}

///|
/// A proxy resolves the origin outside this process, so the origin must still
/// pass the local resolver and address policy before its hostname is sent to
/// the proxy.  Requiring every resolved candidate to be allowed is
/// conservative: the proxy may choose a different candidate than a direct
/// connector would, and allowing only one local result would leave the denied
/// result reachable through the proxy.
async fn Http1PooledRoundTripper::authorize_proxy_origin(
  self : Http1PooledRoundTripper,
  endpoint : @transport.Endpoint,
) -> Result[Unit, ClientError] {
  match self.authorize_endpoint(endpoint, Resolve) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let candidates = match self.resolve_candidates(endpoint) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  for candidate in candidates {
    match self.authorize_endpoint(candidate, Connect) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  self.authorize_endpoint(endpoint, ProxyConnect)
}

///|
async fn http1_pool_connect_tunnel(
  connection : @transport.StreamConnection,
  target : @transport.Endpoint,
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
fn http1_pool_mode_identity(mode : ProxyMode) -> String {
  match mode {
    Direct => "direct"
    HttpForward => "forward"
    HttpsConnect => "connect"
  }
}

///|
fn Http1PooledRoundTripper::connection_key(
  self : Http1PooledRoundTripper,
  endpoint : ClientEndpoint,
) -> ConnectionKey {
  let proxy_endpoint = self.proxy.endpoint()
  let proxy_tls_identity = match proxy_endpoint {
    Some(value) if value.scheme() == "https" => self.proxy_tls_identity
    _ => "plain-proxy"
  }
  ConnectionKey::new(
    endpoint.transport,
    self.proxy.identity_key(),
    if endpoint.secure {
      Some(self.origin_tls_identity)
    } else {
      None
    },
    Http1,
    Some(http1_pool_mode_identity(self.proxy.mode()) + ":" + proxy_tls_identity),
    proxy_endpoint~,
  )
}

///|
fn http1_pool_proxy_authorization(
  headers : @types.HeaderMap,
) -> @types.HeaderValue? {
  headers.get_string("proxy-authorization")
}

///|
async fn Http1PooledRoundTripper::open_session(
  self : Http1PooledRoundTripper,
  endpoint : ClientEndpoint,
  proxy_authorization : @types.HeaderValue?,
) -> Result[Http1PooledSession, ClientError] {
  if endpoint.secure && self.proxy.mode() == HttpForward {
    return Err(
      ClientInvalidOptions(
        "HTTPS origins require CONNECT rather than forward-proxy absolute form",
      ),
    )
  }
  let channel = match self.proxy.mode() {
    Direct => {
      match self.authorize_endpoint(endpoint.transport, Resolve) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      match self.connect_stream(endpoint.transport) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
    }
    HttpForward | HttpsConnect => {
      let proxy_endpoint = match self.proxy.endpoint() {
        Some(value) => value
        None => return Err(ClientInvalidOptions("proxy endpoint is missing"))
      }
      match self.authorize_endpoint(proxy_endpoint, Resolve) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      match self.authorize_endpoint(proxy_endpoint, ProxyConnect) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      match self.authorize_proxy_origin(endpoint.transport) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      let raw = match self.connect_stream(proxy_endpoint) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if proxy_endpoint.scheme() == "https" {
        match self.secure_stream(raw, proxy_endpoint, self.proxy_tls) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
      } else {
        raw
      }
    }
  }
  let routed = match self.proxy.mode() {
    HttpsConnect =>
      match
        http1_pool_connect_tunnel(
          channel,
          endpoint.transport,
          proxy_authorization,
          self.options.limits,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
    Direct | HttpForward => channel
  }
  let stream = if endpoint.secure {
    match self.secure_stream(routed, endpoint.transport, self.origin_tls) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  } else {
    routed
  }
  Http1PooledSession::new(stream, self.options)
}

///|
fn Http1PooledRoundTripper::close_evicted(
  self : Http1PooledRoundTripper,
) -> Unit {
  for id in self.pool.take_evicted_ids() {
    match self.sessions.get(id) {
      Some(session) => {
        self.sessions.remove(id)
        session.close()
      }
      None => ()
    }
  }
}

///|
fn http1_pool_error(error : PoolError) -> ClientError {
  match error {
    InvalidLimits => ClientInvalidOptions("invalid connection pool limits")
    AtCapacity => ClientProtocol("connection pool capacity accounting failed")
    UnknownLease => ClientProtocol("connection pool lost a lease")
    LeaseAlreadyReleased =>
      ClientProtocol("connection lease was released twice")
    LeaseInUse => ClientProtocol("active connection lease cannot be removed")
    IdExhausted => ClientProtocol("connection pool identifier space exhausted")
  }
}

///|
async fn Http1PooledRoundTripper::acquire_session(
  self : Http1PooledRoundTripper,
  key : ConnectionKey,
  endpoint : ClientEndpoint,
  proxy_authorization : @types.HeaderValue?,
) -> Result[(PoolLease, Http1PooledSession), ClientError] {
  self.slots.acquire()
  if self.closed {
    self.slots.release()
    return Err(ClientCancelled("HTTP/1 executor is closed"))
  }
  let acquired = match self.pool.acquire(key) {
    Ok(value) => value
    Err(error) => {
      self.slots.release()
      return Err(http1_pool_error(error))
    }
  }
  let (lease, created) = match acquired {
    Created(id) => ({ key, id, released: false, }, true)
    Reused(id) => ({ key, id, released: false, }, false)
  }
  self.close_evicted()
  let mut transferred = false
  defer (if !transferred {
    ignore(self.pool.release_lease(lease, false))
    self.close_evicted()
    self.slots.release()
  })
  if !created {
    match self.sessions.get(lease.id()) {
      Some(session) => {
        transferred = true
        return Ok((lease, session))
      }
      None => return Err(ClientProtocol("connection pool session is missing"))
    }
  }
  let session = match self.open_session(endpoint, proxy_authorization) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  self.sessions.set(lease.id(), session)
  transferred = true
  Ok((lease, session))
}

///|
fn Http1PooledRoundTripper::finish_lease(
  self : Http1PooledRoundTripper,
  lease : PoolLease,
  session : Http1PooledSession,
  reusable : Bool,
) -> Unit {
  if lease.is_released() {
    return
  }
  let reusable = reusable && !self.closed && session.is_reusable()
  match self.pool.release_lease(lease, reusable) {
    Ok(_) => ()
    Err(_) => {
      lease.released = true
      self.sessions.remove(lease.id())
      session.close()
    }
  }
  self.close_evicted()
  self.slots.release()
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
    @service.ClientConnectionTimeout::ClientConnectionTimeout(phase) =>
      Err(self.phase_timeout(phase))
    @http1.Http1Error::InvalidStartLine(_)
    | @http1.Http1Error::InvalidHeader(_)
    | @http1.Http1Error::InvalidFraming(_)
    | @http1.Http1Error::LimitExceeded(_)
    | @http1.Http1Error::UnexpectedEof(_) =>
      Err(ClientProtocol("HTTP/1 request or response framing failed"))
    error => raise error
  }
}

///|
fn Http1PooledRoundTripper::wire_request(
  self : Http1PooledRoundTripper,
  request : @types.Request[Bytes],
  endpoint : ClientEndpoint,
) -> Result[@types.Request[Unit], ClientError] {
  match self.proxy.mode() {
    HttpForward => h1_client_forward_request(request, endpoint)
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
  let wire_head = match self.wire_request(request, endpoint) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let key = self.connection_key(endpoint)
  let (lease, session) = match
    self.acquire_session(key, endpoint, proxy_authorization) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut handed_off = false
  defer (if !handed_off { self.finish_lease(lease, session, false) })
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
    @service.ClientConnectionTimeout::ClientConnectionTimeout(phase) =>
      Err(self.phase_timeout(phase))
    @http1.Http1Error::InvalidStartLine(_)
    | @http1.Http1Error::InvalidHeader(_)
    | @http1.Http1Error::InvalidFraming(_)
    | @http1.Http1Error::LimitExceeded(_)
    | @http1.Http1Error::UnexpectedEof(_) =>
      Err(ClientProtocol("HTTP/1 response framing failed"))
    @body.BodyLimitExceeded::BodyLimitExceeded(_) =>
      Err(ClientProtocol("HTTP/1 response body exceeds configured limit"))
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

///|
/// Stops new acquisitions and closes every physical session, including
/// active response bodies. The operation is idempotent.
pub fn Http1PooledRoundTripper::close(self : Http1PooledRoundTripper) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  for session in self.sessions.values() {
    session.close()
  }
  self.sessions.clear()
}

///|
pub fn Http1PooledRoundTripper::connection_count(
  self : Http1PooledRoundTripper,
) -> Int {
  self.sessions.length()
}

///|
pub fn Http1PooledRoundTripper::idle_connection_count(
  self : Http1PooledRoundTripper,
) -> Int {
  self.pool.idle_len()
}
