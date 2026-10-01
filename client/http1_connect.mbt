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
async fn Http1PooledRoundTripper::secure_stream(
  self : Http1PooledRoundTripper,
  connection : @transport.StreamConnection,
  endpoint : @types.Endpoint,
  configured : @transport.TlsOptions,
) -> Result[@transport.StreamConnection, ClientError] {
  let mut transferred = false
  defer (if !transferred { connection.close() })
  let options : @transport.TlsOptions = {
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
  endpoint : @types.Endpoint,
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
  endpoint : @types.Endpoint,
) -> Result[Array[@types.Endpoint], ClientError] {
  if @types.IpAddress::parse(endpoint.host()) is Ok(_) {
    return Ok([endpoint])
  }
  let resolve = match self.resolve {
    Some(value) => value
    None =>
      return Err(
        ClientInvalidOptions("hostname endpoints require an explicit resolver"),
      )
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
  endpoint : @types.Endpoint,
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
