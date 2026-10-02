///|
/// OpenSSL 3 TLS over injected byte streams. PEM roots and identities stay in
/// memory. Custom CA roots replace system roots. No DNS or socket operation
/// occurs in this provider. Linux, macOS and Windows use the same dynamically
/// resolved OpenSSL ABI; an unavailable runtime returns `Unsupported`.
pub struct NativeTlsProvider {
  allow_system_roots : Bool
}

///|
pub fn NativeTlsProvider::new(
  allow_system_roots? : Bool = true,
) -> NativeTlsProvider {
  { allow_system_roots, }
}

///|
priv struct NativeTlsSession {
  ssl : OpenSsl
  connection : @transport.StreamConnection
  read_lock : @async.Mutex
  write_lock : @async.Mutex
  input_lock : @async.Mutex
  output_lock : @async.Mutex
  mut input_generation : Int64
  mut closed : Bool
}

///|
fn NativeTlsSession::new(
  ssl : OpenSsl,
  connection : @transport.StreamConnection,
) -> NativeTlsSession {
  {
    ssl,
    connection,
    read_lock: Mutex(),
    write_lock: Mutex(),
    input_lock: Mutex(),
    output_lock: Mutex(),
    input_generation: 0L,
    closed: false,
  }
}

///|
fn NativeTlsSession::close(self : NativeTlsSession) -> Unit {
  if !self.closed {
    self.closed = true
    self.ssl.close()
    self.connection.close()
  }
}

///|
fn OpenSsl::failure(
  self : OpenSsl,
  operation : @transport.TlsOperation,
) -> @transport.TlsError {
  NativeFailure(
    operation,
    self.error_code(),
    self.verify_code(),
    @utf8.decode_lossy(self.error_message()),
  )
}

///|
fn OpenSsl::transport_failure(
  self : OpenSsl,
  operation : @transport.TransportOperation,
) -> @transport.TransportError {
  NativeFailure(
    operation,
    self.error_code(),
    self.verify_code(),
    @utf8.decode_lossy(self.error_message()),
  )
}

///|
async fn NativeTlsSession::flush(
  self : NativeTlsSession,
) -> Result[Unit, @transport.TransportError] {
  self.output_lock.acquire()
  defer self.output_lock.release()
  if self.closed {
    return Err(Closed)
  }
  for ;; {
    let bytes = self.ssl.drain()
    if bytes.is_empty() {
      return Ok(())
    }
    match self.connection.write(bytes) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
}

///|
async fn NativeTlsSession::receive(
  self : NativeTlsSession,
  generation : Int64,
) -> Result[Unit, @transport.TransportError] {
  self.input_lock.acquire()
  defer self.input_lock.release()
  if self.closed {
    return Err(Closed)
  }
  // Another reader may already have supplied the bytes this operation needed.
  if self.input_generation != generation {
    return Ok(())
  }
  match self.connection.read(16384) {
    Err(error) => Err(error)
    Ok(None) => Err(Failed(Receive, "TLS stream ended without close_notify"))
    Ok(Some(bytes)) => {
      if self.closed {
        return Err(Closed)
      }
      if bytes.is_empty() || self.ssl.feed(bytes) != bytes.length() {
        return Err(Failed(Receive, "TLS input made no progress"))
      }
      self.input_generation += 1L
      Ok(())
    }
  }
}

///|
async fn NativeTlsSession::handshake(
  self : NativeTlsSession,
) -> Result[Unit, @transport.TlsError] {
  for ;; {
    if self.closed {
      return Err(Closed)
    }
    let generation = self.input_generation
    let status = self.ssl.handshake()
    let failure = if status < 0 {
      Some(self.ssl.failure(Handshake))
    } else {
      None
    }
    match self.flush() {
      Err(error) => return Err(Transport(error))
      Ok(_) => ()
    }
    match status {
      1 => return Ok(())
      2 =>
        match self.receive(generation) {
          Err(error) => return Err(Transport(error))
          Ok(_) => ()
        }
      3 => ()
      _ =>
        return Err(failure.unwrap_or(HandshakeFailed("TLS handshake closed")))
    }
  }
}

///|
async fn NativeTlsSession::read(
  self : NativeTlsSession,
  max_bytes : Int,
) -> Result[Bytes?, @transport.TransportError] {
  errdefer self.close()
  self.read_lock.acquire()
  defer self.read_lock.release()
  let buffer = FixedArray::make(max_bytes.min(16384), b'\x00')
  let count = Ref(0)
  for ;; {
    if self.closed {
      return Err(Closed)
    }
    let generation = self.input_generation
    let status = self.ssl.read(buffer, count)
    let failure = if status < 0 {
      Some(self.ssl.transport_failure(Receive))
    } else {
      None
    }
    match self.flush() {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
    match status {
      1 => return Ok(Some(Bytes::from_array(buffer[:count.val].to_owned())))
      6 => return Ok(None)
      2 =>
        match self.receive(generation) {
          Err(error) => return Err(error)
          Ok(_) => ()
        }
      3 => ()
      _ => return Err(failure.unwrap_or(Failed(Receive, "TLS read failed")))
    }
  }
}

///|
async fn NativeTlsSession::write(
  self : NativeTlsSession,
  bytes : Bytes,
) -> Result[Unit, @transport.TransportError] {
  errdefer self.close()
  self.write_lock.acquire()
  defer self.write_lock.release()
  let count = Ref(0)
  let mut offset = 0
  while offset < bytes.length() {
    if self.closed {
      return Err(Closed)
    }
    let generation = self.input_generation
    let status = self.ssl.write(
      bytes,
      offset,
      (bytes.length() - offset).min(16384),
      count,
    )
    let failure = if status < 0 {
      Some(self.ssl.transport_failure(Send))
    } else {
      None
    }
    match self.flush() {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
    match status {
      1 => offset += count.val
      2 =>
        match self.receive(generation) {
          Err(error) => return Err(error)
          Ok(_) => ()
        }
      3 => ()
      _ => return Err(failure.unwrap_or(Failed(Send, "TLS write failed")))
    }
  }
  Ok(())
}

///|
fn native_tls_wire_version(version : @transport.TlsVersion) -> Int {
  match version {
    Tls12 => 0x0303
    Tls13 => 0x0304
  }
}

///|
fn native_tls_wire_alpn(protocols : Array[String]) -> Bytes {
  let bytes : Array[Byte] = []
  for protocol in protocols {
    let encoded = @utf8.encode(protocol)
    bytes.push(encoded.length().to_byte())
    for byte in encoded {
      bytes.push(byte)
    }
  }
  Bytes::from_array(bytes)
}

///|
async fn NativeTlsProvider::handshake(
  self : NativeTlsProvider,
  connection : @transport.StreamConnection,
  options : @transport.TlsOptions,
  server : Bool,
) -> Result[@transport.SecureConnection, @transport.TlsError] {
  let validation = if server {
    options.validate_server()
  } else {
    options.validate_client()
  }
  match validation {
    Err(error) => return Err(InvalidOptions(error))
    Ok(_) => ()
  }
  let (certificate, private_key) = if server {
    (options.server_certificate, options.server_private_key)
  } else {
    (options.client_certificate, options.client_private_key)
  }
  if server && certificate is None {
    return Err(InvalidOptions(IncompleteServerCertificate))
  }
  let host = options.server_name.unwrap_or("")
  if host.contains("\u0000") {
    return Err(InvalidOptions(MissingServerName))
  }
  let alpn = native_tls_wire_alpn(options.alpn)
  if alpn.length() > 65535 {
    return Err(InvalidOptions(InvalidAlpn))
  }
  let ssl = openssl_new(
    server,
    options.verify_peer,
    self.allow_system_roots,
    native_tls_wire_version(options.min_version),
    options.max_version.map(native_tls_wire_version).unwrap_or(0),
    @utf8.encode(host),
    @types.IpAddress::parse(host) is Ok(_),
    options.trust_anchors.unwrap_or(b""),
    options.revocation_lists.unwrap_or(b""),
    options.require_crl,
    options.require_ocsp,
    options.ocsp_response.unwrap_or(b""),
    certificate.unwrap_or(b""),
    private_key.unwrap_or(b""),
    alpn,
  )
  let session = NativeTlsSession::new(ssl, connection)
  let mut transferred = false
  defer (if !transferred { session.close() })
  if !ssl.available() {
    return Err(Unsupported)
  }
  if !ssl.ready() {
    return Err(ssl.failure(Configure))
  }
  let result = session.handshake()
  match result {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  if !server && !ssl.check_ocsp(options.require_ocsp) {
    return Err(ssl.failure(Handshake))
  }
  let version : @transport.TlsVersion = match ssl.version() {
    0x0303 => Tls12
    0x0304 => Tls13
    _ => return Err(HandshakeFailed("unsupported negotiated TLS version"))
  }
  let selected = ssl.alpn()
  let negotiated = if selected.is_empty() {
    None
  } else {
    Some(@utf8.decode_lossy(selected))
  }
  match negotiated {
    Some(protocol) if !options.alpn.contains(protocol) =>
      return Err(HandshakeFailed("peer selected an unoffered ALPN protocol"))
    None if !options.alpn.contains("http/1.1") =>
      return Err(HandshakeFailed("peer did not negotiate required ALPN"))
    _ => ()
  }
  let authenticated = options.verify_peer && ssl.peer_authenticated()
  if options.verify_peer && !authenticated {
    return Err(VerificationFailed("TLS peer certificate was not authenticated"))
  }
  let transport = @transport.StreamConnection::new(
    connection.endpoint(),
    async fn(max_bytes) { session.read(max_bytes) },
    async fn(bytes) { session.write(bytes) },
    fn() { session.close() },
  )
  transferred = true
  Ok(
    @transport.SecureConnection::new(
      transport,
      version,
      @utf8.decode_lossy(ssl.cipher()),
      negotiated,
      if server {
        None
      } else {
        Some(host)
      },
      authenticated,
    ),
  )
}

///|
pub impl @transport.TlsProvider for NativeTlsProvider with fn client_handshake(
  self,
  connection,
  options,
) {
  self.handshake(connection, options, false)
}

///|
pub impl @transport.TlsProvider for NativeTlsProvider with fn server_handshake(
  self,
  connection,
  options,
) {
  self.handshake(connection, options, true)
}
