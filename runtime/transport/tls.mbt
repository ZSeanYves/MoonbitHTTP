///|
pub(all) enum TlsVersion {
  Tls12
  Tls13
} derive(Eq, Debug)

///|
pub(all) struct TlsOptions {
  verify_peer : Bool
  server_name : String?
  alpn : Array[String]
  min_version : TlsVersion
  max_version : TlsVersion?
  enable_early_data : Bool
  /// None permits the provider's default trust policy; Some must be nonempty
  /// and replaces ambient roots in native providers.
  trust_anchors : Bytes?
  /// PEM encoded CRLs used for native chain revocation checks.
  revocation_lists : Bytes?
  /// Require a CRL and fail closed when no applicable CRL is available.
  require_crl : Bool
  /// Client-only: require a signed, fresh OCSP staple for the server certificate.
  require_ocsp : Bool
  /// DER encoded OCSP response stapled by a native TLS server.
  ocsp_response : Bytes?
  client_certificate : Bytes?
  client_private_key : Bytes?
  server_certificate : Bytes?
  server_private_key : Bytes?
}

///|
pub fn TlsOptions::defaults() -> TlsOptions {
  {
    verify_peer: true,
    server_name: None,
    alpn: ["h2", "http/1.1"],
    min_version: Tls13,
    max_version: None,
    enable_early_data: false,
    trust_anchors: None,
    revocation_lists: None,
    require_crl: false,
    require_ocsp: false,
    ocsp_response: None,
    client_certificate: None,
    client_private_key: None,
    server_certificate: None,
    server_private_key: None,
  }
}

///|
pub(all) suberror TlsOptionsError {
  MissingServerName
  InvalidAlpn
  InvalidVersionRange
  EarlyDataRequiresReplayPolicy
  IncompleteClientCertificate
  IncompleteServerCertificate
  RevocationRequiresVerification
  MissingRevocationList
  OcspRequiresClientRole
  EmptyTrustAnchors
} derive(Eq, Debug)

///|
pub fn TlsOptions::validate_common(
  self : TlsOptions,
) -> Result[Unit, TlsOptionsError] {
  if self.alpn.is_empty() {
    return Err(InvalidAlpn)
  }
  for protocol in self.alpn {
    let protocol_bytes = @utf8.encode(protocol)
    if protocol.is_empty() ||
      protocol_bytes.length() > 255 ||
      protocol.contains("\r") ||
      protocol.contains("\n") {
      return Err(InvalidAlpn)
    }
  }
  match self.max_version {
    Some(maximum) if self.min_version == Tls13 && maximum == Tls12 =>
      return Err(InvalidVersionRange)
    _ => ()
  }
  if self.enable_early_data {
    return Err(EarlyDataRequiresReplayPolicy)
  }
  match self.trust_anchors {
    Some(roots) if roots.is_empty() => return Err(EmptyTrustAnchors)
    _ => ()
  }
  if (self.require_crl || self.require_ocsp) && !self.verify_peer {
    return Err(RevocationRequiresVerification)
  }
  if self.require_crl {
    match self.revocation_lists {
      Some(crls) if !crls.is_empty() => ()
      _ => return Err(MissingRevocationList)
    }
  }
  match self.revocation_lists {
    Some(crls) if crls.is_empty() => return Err(MissingRevocationList)
    _ => ()
  }
  match self.ocsp_response {
    Some(response) if response.is_empty() => return Err(MissingRevocationList)
    _ => ()
  }
  match (self.client_certificate, self.client_private_key) {
    (Some(certificate), Some(key)) if certificate.is_empty() || key.is_empty() =>
      return Err(IncompleteClientCertificate)
    (Some(_), None) | (None, Some(_)) => return Err(IncompleteClientCertificate)
    _ => ()
  }
  match (self.server_certificate, self.server_private_key) {
    (Some(certificate), Some(key)) if certificate.is_empty() || key.is_empty() =>
      return Err(IncompleteServerCertificate)
    (Some(_), None) | (None, Some(_)) => return Err(IncompleteServerCertificate)
    _ => ()
  }
  Ok(())
}

///|
/// Returns a copy with the endpoint host as SNI only when the caller did not
/// explicitly configure a server name. Explicit identity configuration is
/// never silently replaced.
pub fn TlsOptions::for_server_name(
  self : TlsOptions,
  server_name : String,
) -> TlsOptions {
  match self.server_name {
    Some(_) => self
    None => { ..self, server_name: Some(server_name), }
  }
}

///|
/// A client handshake always carries an explicit endpoint identity, including
/// when certificate verification is intentionally disabled for a test peer.
pub fn TlsOptions::validate_client(
  self : TlsOptions,
) -> Result[Unit, TlsOptionsError] {
  match self.validate_common() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match self.server_name {
    Some(name) if !name.is_empty() => Ok(())
    _ => Err(MissingServerName)
  }
}

///|
/// Server-side options do not require SNI. Certificate/key pairing and ALPN
/// constraints are still checked by the common validator.
pub fn TlsOptions::validate_server(
  self : TlsOptions,
) -> Result[Unit, TlsOptionsError] {
  if self.require_ocsp {
    return Err(OcspRequiresClientRole)
  }
  self.validate_common()
}

///|
pub fn TlsOptions::for_quic(server_name : String) -> TlsOptions {
  {
    ..TlsOptions::defaults(),
    server_name: Some(server_name),
    alpn: ["h3"],
    min_version: Tls13,
    max_version: Some(Tls13),
  }
}

///|
pub(all) enum TlsOperation {
  Configure
  Handshake
  Read
  Write
  Shutdown
} derive(Eq, Debug)

///|
pub(all) suberror TlsError {
  InvalidOptions(TlsOptionsError)
  VerificationFailed(String)
  HostnameMismatch
  Alert(Int)
  HandshakeFailed(String)
  NativeFailure(TlsOperation, UInt64, Int64, String)
  Transport(TransportError)
  Cancelled
  InvalidTrafficSecret
  InvalidPacketNumber
  PacketProtectionFailed
  PacketAuthenticationFailed
  UnsupportedCipherSuite
  Unsupported
  Closed
} derive(Eq, Debug)

///|
pub(all) struct SecureConnection {
  transport : StreamConnection
  version : TlsVersion
  cipher_suite : String
  alpn : String?
  peer_identity : String?
  authenticated : Bool
}

///|
pub fn SecureConnection::new(
  transport : StreamConnection,
  version : TlsVersion,
  cipher_suite : String,
  alpn : String?,
  peer_identity : String?,
  authenticated : Bool,
) -> SecureConnection {
  { transport, version, cipher_suite, alpn, peer_identity, authenticated, }
}

///|
pub fn SecureConnection::version(self : SecureConnection) -> TlsVersion {
  self.version
}

///|
pub fn SecureConnection::cipher_suite(self : SecureConnection) -> String {
  self.cipher_suite
}

///|
/// Returns the protocol selected by ALPN, or `None` when the peer completed a
/// valid handshake without negotiating the extension.
pub fn SecureConnection::alpn(self : SecureConnection) -> String? {
  self.alpn
}

///|
pub fn SecureConnection::peer_identity(self : SecureConnection) -> String? {
  self.peer_identity
}

///|
pub fn SecureConnection::is_authenticated(self : SecureConnection) -> Bool {
  self.authenticated
}

///|
pub async fn SecureConnection::read(
  self : SecureConnection,
  max_bytes : Int,
) -> Result[Bytes?, TransportError] {
  self.transport.read(max_bytes)
}

///|
pub async fn SecureConnection::write(
  self : SecureConnection,
  bytes : Bytes,
) -> Result[Unit, TransportError] {
  self.transport.write(bytes)
}

///|
pub fn SecureConnection::close(self : SecureConnection) -> Unit {
  self.transport.close()
}

///|
pub fn SecureConnection::is_closed(self : SecureConnection) -> Bool {
  self.transport.is_closed()
}

///|
pub(open) trait TlsProvider {
  async fn client_handshake(Self, StreamConnection, TlsOptions) -> Result[
    SecureConnection,
    TlsError,
  ]
  async fn server_handshake(Self, StreamConnection, TlsOptions) -> Result[
    SecureConnection,
    TlsError,
  ]
}

///|
pub struct UnsupportedProvider(Unit)

///|
pub fn UnsupportedProvider::new() -> UnsupportedProvider {
  UnsupportedProvider(())
}

///|
pub impl TlsProvider for UnsupportedProvider with fn client_handshake(
  _self,
  _transport,
  options,
) {
  match options.validate_client() {
    Ok(_) => Err(Unsupported)
    Err(error) => Err(InvalidOptions(error))
  }
}

///|
pub impl TlsProvider for UnsupportedProvider with fn server_handshake(
  _self,
  _transport,
  options,
) {
  match options.validate_server() {
    Ok(_) => Err(Unsupported)
    Err(error) => Err(InvalidOptions(error))
  }
}
