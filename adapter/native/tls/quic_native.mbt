///|
priv type OpenSslQuic

///|
#borrow(ssl, params)
extern "C" fn openssl_quic_new(
  ssl : OpenSsl,
  params : Bytes,
  limit : Int,
) -> OpenSslQuic = "moon_http_quic_tls_new"

///|
#borrow(self)
extern "C" fn OpenSslQuic::ready(self : OpenSslQuic) -> Bool = "moon_http_quic_tls_ready"

///|
#borrow(self)
extern "C" fn OpenSslQuic::available(self : OpenSslQuic) -> Bool = "moon_http_quic_tls_available"

///|
#borrow(self)
extern "C" fn OpenSslQuic::alert(self : OpenSslQuic) -> Int = "moon_http_quic_tls_alert"

///|
#borrow(self)
extern "C" fn OpenSslQuic::close(self : OpenSslQuic) -> Unit = "moon_http_quic_tls_close"

///|
#borrow(self, bytes)
extern "C" fn OpenSslQuic::feed(
  self : OpenSslQuic,
  level : Int,
  bytes : Bytes,
) -> Bool = "moon_http_quic_tls_feed"

///|
#borrow(self)
extern "C" fn OpenSslQuic::event(self : OpenSslQuic) -> Bytes = "moon_http_quic_tls_event"

///|
#borrow(self)
extern "C" fn OpenSslQuic::has_params(self : OpenSslQuic) -> Bool = "moon_http_quic_tls_has_params"

///|
#borrow(self)
extern "C" fn OpenSslQuic::peer_params(self : OpenSslQuic) -> Bytes = "moon_http_quic_tls_params"

///|
/// An OpenSSL >= 3.5 TLS 1.3 engine for third-party QUIC transports. It performs
/// real client/server handshakes and emits raw CRYPTO bytes and traffic secrets.
/// Each instance owns one handshake. No socket is opened by this provider.
pub struct NativeQuicTlsProvider {
  priv server : Bool
  priv allow_system_roots : Bool
  priv max_handshake_bytes : Int
  priv mut ssl : OpenSsl?
  priv mut quic : OpenSslQuic?
  priv mut options : @transport.TlsOptions?
  priv mut complete : Bool
  priv mut failure : @transport.TlsError?
}

///|
pub fn NativeQuicTlsProvider::new(
  server? : Bool = false,
  allow_system_roots? : Bool = true,
  max_handshake_bytes? : Int = 1024 * 1024,
) -> NativeQuicTlsProvider {
  {
    server,
    allow_system_roots,
    max_handshake_bytes,
    ssl: None,
    quic: None,
    options: None,
    complete: false,
    failure: None,
  }
}

///|
pub fn NativeQuicTlsProvider::close(self : NativeQuicTlsProvider) -> Unit {
  match self.quic {
    Some(quic) => quic.close()
    None => ()
  }
  match self.ssl {
    Some(ssl) => ssl.close()
    None => ()
  }
  self.quic = None
  self.ssl = None
  self.failure = Some(Closed)
}

///|
fn NativeQuicTlsProvider::failed(
  self : NativeQuicTlsProvider,
  error : @transport.TlsError,
) -> @transport.TlsError {
  self.close()
  self.failure = Some(error)
  error
}

///|
fn quic_native_level(value : Int) -> @transport.QuicEncryptionLevel? {
  match value {
    0 => Some(QuicInitial)
    2 => Some(QuicHandshake)
    3 => Some(QuicApplication)
    _ => None
  }
}

///|
fn NativeQuicTlsProvider::advance(
  self : NativeQuicTlsProvider,
) -> Result[Array[@transport.QuicTlsEvent], @transport.TlsError] {
  let (ssl, quic, options) = match (self.ssl, self.quic, self.options) {
    (Some(ssl), Some(quic), Some(options)) => (ssl, quic, options)
    _ => return Err(Closed)
  }
  let status = if self.complete {
    let buffer = FixedArray::make(1, b'\x00')
    let count : Ref[Int] = { val: 0, }
    ssl.read(buffer, count)
  } else {
    ssl.handshake()
  }
  if quic.alert() != 0 {
    return Err(self.failed(Alert(quic.alert())))
  }
  if !quic.ready() {
    return Err(
      self.failed(HandshakeFailed("QUIC TLS callback limit or state failure")),
    )
  }
  if status != 1 && status != 2 && status != 3 {
    return Err(self.failed(ssl.failure(Handshake)))
  }
  let output : Array[@transport.QuicTlsEvent] = []
  for ;; {
    let event = quic.event()
    if event.is_empty() {
      break
    }
    let level = match quic_native_level(event[1].to_int()) {
      Some(value) => value
      None =>
        return Err(
          self.failed(HandshakeFailed("unexpected QUIC TLS protection level")),
        )
    }
    let payload = event[3:].to_owned()
    if event[0] == b'\x01' {
      output.push(HandshakeBytes(level, payload))
    } else {
      let suite : @transport.QuicTlsCipherSuite = match
        @utf8.decode_lossy(ssl.cipher()) {
        "TLS_AES_128_GCM_SHA256" => TlsAes128GcmSha256
        "TLS_AES_256_GCM_SHA384" => TlsAes256GcmSha384
        _ => return Err(self.failed(UnsupportedCipherSuite))
      }
      let direction : @transport.QuicSecretDirection = if event[2] == b'\x00' {
        QuicReadSecret
      } else {
        QuicWriteSecret
      }
      output.push(TrafficSecret(level, direction, suite, payload))
    }
  }
  if status == 1 && !self.complete {
    if ssl.version() != 0x0304 || ssl.alpn() != b"h3" || !quic.has_params() {
      return Err(
        self.failed(
          HandshakeFailed(
            "QUIC requires TLS 1.3, h3 ALPN and peer transport parameters",
          ),
        ),
      )
    }
    if options.verify_peer && !ssl.peer_authenticated() {
      return Err(
        self.failed(
          VerificationFailed("QUIC TLS peer certificate was not authenticated"),
        ),
      )
    }
    if !self.server && !ssl.check_ocsp(options.require_ocsp) {
      return Err(self.failed(ssl.failure(Handshake)))
    }
    self.complete = true
    output.push(HandshakeComplete("h3", quic.peer_params()))
  }
  Ok(output)
}

///|
pub impl @transport.QuicTlsProvider for NativeQuicTlsProvider with fn start(
  self,
  options,
  transport_params,
) {
  if self.failure is Some(error) {
    return Err(error)
  }
  if self.ssl is Some(_) {
    return Err(HandshakeFailed("QUIC TLS provider already started"))
  }
  let validation = if self.server {
    options.validate_server()
  } else {
    options.validate_client()
  }
  match validation {
    Ok(_) => ()
    Err(error) => return Err(self.failed(InvalidOptions(error)))
  }
  if self.max_handshake_bytes < 4 ||
    transport_params.length() > 65535 ||
    options.min_version != Tls13 ||
    options.max_version == Some(Tls12) ||
    options.alpn != ["h3"] {
    return Err(self.failed(HandshakeFailed("invalid QUIC TLS configuration")))
  }
  let (certificate, private_key) = if self.server {
    (options.server_certificate, options.server_private_key)
  } else {
    (options.client_certificate, options.client_private_key)
  }
  if self.server && certificate is None {
    return Err(self.failed(InvalidOptions(IncompleteServerCertificate)))
  }
  let host = options.server_name.unwrap_or("")
  if host.contains("\u0000") {
    return Err(self.failed(InvalidOptions(MissingServerName)))
  }
  let ssl = openssl_new(
    self.server,
    options.verify_peer,
    self.allow_system_roots,
    0x0304,
    0x0304,
    @utf8.encode(host),
    @types.IpAddress::parse(host) is Ok(_),
    options.trust_anchors.unwrap_or(b""),
    options.revocation_lists.unwrap_or(b""),
    options.require_crl,
    options.require_ocsp,
    options.ocsp_response.unwrap_or(b""),
    certificate.unwrap_or(b""),
    private_key.unwrap_or(b""),
    b"\x02h3",
  )
  self.ssl = Some(ssl)
  if !ssl.available() {
    return Err(self.failed(Unsupported))
  }
  if !ssl.ready() {
    return Err(self.failed(ssl.failure(Configure)))
  }
  let quic = openssl_quic_new(ssl, transport_params, self.max_handshake_bytes)
  self.quic = Some(quic)
  if !quic.available() {
    return Err(self.failed(Unsupported))
  }
  if !quic.ready() {
    return Err(
      self.failed(HandshakeFailed("OpenSSL QUIC TLS initialization failed")),
    )
  }
  self.options = Some(options)
  self.advance()
}

///|
pub impl @transport.QuicTlsProvider for NativeQuicTlsProvider with fn receive_handshake(
  self,
  message,
) {
  if self.failure is Some(error) {
    return Err(error)
  }
  let quic = match self.quic {
    Some(value) => value
    None => return Err(HandshakeFailed("QUIC TLS provider was not started"))
  }
  let level = match message.level {
    QuicInitial => 0
    QuicHandshake => 2
    QuicApplication => 3
  }
  if !quic.feed(level, message.encoded) {
    return Err(self.failed(HandshakeFailed("QUIC TLS input limit exceeded")))
  }
  self.advance()
}

///|
pub extend NativeQuicTlsProvider with @transport.QuicTlsProvider::{
  start,
  receive_handshake,
}
