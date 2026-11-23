///|
priv struct ClientNetwork {
  connect : async (@types.Endpoint, @transport.ConnectOptions) -> Result[
    @transport.StreamConnection,
    @transport.TransportError,
  ]
  tls_handshake : async (@transport.StreamConnection, @transport.TlsOptions) -> Result[
    @transport.SecureConnection,
    @transport.TlsError,
  ]
  resolve : (async (String, @transport.ResolveOptions) -> Result[
    Array[@types.IpAddress],
    @transport.TransportError,
  ])?
  authorize : (@types.Endpoint, @transport.PolicyOperation) -> Result[
    Unit,
    @transport.PolicyError,
  ]
  now_millis : () -> Int64
}

///|
fn[
  C : @transport.StreamConnector,
  R : @transport.NameResolver,
  T : @transport.TlsProvider,
  P : @transport.NetworkPolicy,
  K : @transport.Clock,
] ClientNetwork::from_capabilities(
  connector : C,
  resolver : R,
  tls_provider : T,
  policy : P,
  clock : K,
) -> ClientNetwork {
  {
    connect: async fn(endpoint, options) {
      @transport.StreamConnector::connect(connector, endpoint, options)
    },
    tls_handshake: async fn(connection, options) {
      @transport.TlsProvider::client_handshake(
        tls_provider, connection, options,
      )
    },
    resolve: Some(async fn(host, options) {
      @transport.NameResolver::resolve(resolver, host, options)
    }),
    authorize: fn(endpoint, operation) {
      @transport.NetworkPolicy::authorize(policy, endpoint, operation)
    },
    now_millis: fn() { @transport.Clock::monotonic_millis(clock) },
  }
}

///|
priv struct ClientDialer {
  network : ClientNetwork
  connect_options : @transport.ConnectOptions
  resolve_options : @transport.ResolveOptions
  tls_timeout_ms : Int?
}

///|
fn ClientDialer::new(
  network : ClientNetwork,
  connect_options : @transport.ConnectOptions,
  resolve_options : @transport.ResolveOptions,
  tls_timeout_ms : Int?,
) -> Result[ClientDialer, ClientError] {
  if connect_options.validate() is Err(_) {
    return Err(ClientInvalidOptions("invalid connect options"))
  }
  if resolve_options.validate() is Err(_) {
    return Err(ClientInvalidOptions("invalid resolve options"))
  }
  if tls_timeout_ms is Some(ms) && ms <= 0 {
    return Err(ClientInvalidOptions("TLS timeout must be positive"))
  }
  Ok({ network, connect_options, resolve_options, tls_timeout_ms, })
}

///|
fn client_deadline(start : Int64, timeout_ms : Int) -> Int64 {
  let timeout = timeout_ms.to_int64()
  if start > @int64.MAX_VALUE - timeout {
    @int64.MAX_VALUE
  } else {
    start + timeout
  }
}

///|
fn client_phase_timeout(
  phase : ClientPhase,
  started : Int64,
  timeout : Int,
) -> ClientError {
  ClientTimeout(phase, timeout.to_int64(), client_deadline(started, timeout))
}

///|
fn ClientDialer::timeout_error(
  self : ClientDialer,
  phase : ClientPhase,
  timeout_ms : Int,
) -> ClientError {
  let start = (self.network.now_millis)().max(0L)
  client_phase_timeout(phase, start, timeout_ms)
}

///|
fn client_stream_from_secure(
  secure : @transport.SecureConnection,
  endpoint : @types.Endpoint,
) -> @transport.StreamConnection {
  @transport.StreamConnection::new(
    endpoint,
    async fn(max_bytes) { secure.read(max_bytes) },
    async fn(bytes) { secure.write(bytes) },
    fn() { secure.close() },
  )
}

///|
async fn ClientDialer::secure_stream(
  self : ClientDialer,
  connection : @transport.StreamConnection,
  endpoint : @types.Endpoint,
  configured : @transport.TlsOptions,
  alpn~ : String,
) -> Result[@transport.StreamConnection, ClientError] {
  let mut transferred = false
  defer (if !transferred { connection.close() })
  let options : @transport.TlsOptions = {
    ..configured.for_server_name(endpoint.host()),
    alpn: [alpn],
  }
  match options.validate_client() {
    Ok(_) => ()
    Err(_) => return Err(ClientInvalidOptions("invalid endpoint TLS options"))
  }
  let started = (self.network.now_millis)().max(0L)
  let result = match self.tls_timeout_ms {
    Some(timeout) =>
      @async.with_timeout(timeout, async fn() {
        (self.network.tls_handshake)(connection, options)
      }) catch {
        @async.TimeoutError =>
          return Err(client_phase_timeout(ClientTlsHandshake, started, timeout))
        error => raise error
      }
    None => (self.network.tls_handshake)(connection, options)
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
  let negotiated = secure.alpn()
  if negotiated != Some(alpn) && !(alpn == "http/1.1" && negotiated is None) {
    secure.close()
    return Err(ClientProtocol("TLS did not negotiate " + alpn))
  }
  let stream = client_stream_from_secure(secure, endpoint)
  transferred = true
  Ok(stream)
}

///|
fn ClientDialer::authorize_endpoint(
  self : ClientDialer,
  endpoint : @types.Endpoint,
  operation : @transport.PolicyOperation,
) -> Result[Unit, ClientError] {
  match (self.network.authorize)(endpoint, operation) {
    Ok(_) => Ok(())
    Err(error) => Err(ClientPolicy(error))
  }
}

///|
async fn ClientDialer::resolve_candidates(
  self : ClientDialer,
  endpoint : @types.Endpoint,
) -> Result[Array[@types.Endpoint], ClientError] {
  if @types.IpAddress::parse(endpoint.host()) is Ok(_) {
    return Ok([endpoint])
  }
  let resolve = match self.network.resolve {
    Some(value) => value
    None =>
      return Err(
        ClientInvalidOptions("hostname endpoints require an explicit resolver"),
      )
  }
  let started = (self.network.now_millis)().max(0L)
  let result = match self.resolve_options.timeout_ms {
    Some(timeout) =>
      @async.with_timeout(timeout, async fn() {
        resolve(endpoint.host(), self.resolve_options)
      }) catch {
        @async.TimeoutError =>
          return Err(client_phase_timeout(ClientResolve, started, timeout))
        error => raise error
      }
    None => resolve(endpoint.host(), self.resolve_options)
  }
  let addresses = match result {
    Ok(value) => value
    Err(Timeout(Resolve)) => {
      let timeout = self.resolve_options.timeout_ms.unwrap_or(0)
      return Err(client_phase_timeout(ClientResolve, started, timeout))
    }
    Err(error) => return Err(ClientTransport(error))
  }
  if addresses.is_empty() {
    return Err(
      ClientTransport(Failed(Resolve, "resolver returned no addresses")),
    )
  }
  let candidates : Array[@types.Endpoint] = []
  let count = addresses.length().min(self.resolve_options.max_results)
  for index in 0..<count {
    let address = match @types.IpAddress::parse(addresses[index].value()) {
      Ok(value) => value
      Err(_) =>
        return Err(
          ClientTransport(
            Failed(Resolve, "resolver returned a non-numeric address"),
          ),
        )
    }
    let candidate = match
      @types.Endpoint::new(endpoint.scheme(), address.value(), endpoint.port()) {
      Ok(value) => value
      Err(error) => return Err(ClientTransport(InvalidEndpoint(error)))
    }
    if !candidates.contains(candidate) {
      candidates.push(candidate)
    }
  }
  Ok(candidates)
}

///|
async fn ClientDialer::connect_candidate(
  self : ClientDialer,
  endpoint : @types.Endpoint,
) -> Result[@transport.StreamConnection, ClientError] {
  let started = (self.network.now_millis)().max(0L)
  let result = match self.connect_options.timeout_ms {
    Some(timeout) =>
      @async.with_timeout(timeout, async fn() {
        (self.network.connect)(endpoint, self.connect_options)
      }) catch {
        @async.TimeoutError =>
          return Err(client_phase_timeout(ClientConnect, started, timeout))
        error => raise error
      }
    None => (self.network.connect)(endpoint, self.connect_options)
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
      let timeout = self.connect_options.timeout_ms.unwrap_or(0)
      Err(client_phase_timeout(ClientConnect, started, timeout))
    }
    Err(error) => Err(ClientTransport(error))
  }
}

///|
async fn ClientDialer::connect_stream(
  self : ClientDialer,
  endpoint : @types.Endpoint,
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
async fn ClientDialer::open_direct(
  self : ClientDialer,
  endpoint : ClientEndpoint,
  tls : @transport.TlsOptions,
  alpn~ : String,
) -> Result[@transport.StreamConnection, ClientError] {
  match self.authorize_endpoint(endpoint.transport, Resolve) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let connection = match self.connect_stream(endpoint.transport) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if endpoint.secure {
    self.secure_stream(connection, endpoint.transport, tls, alpn~)
  } else {
    Ok(connection)
  }
}
