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
  trust_anchors : Bytes?
  client_certificate : Bytes?
  client_private_key : Bytes?
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
    client_certificate: None,
    client_private_key: None,
  }
}

///|
pub(all) suberror TlsOptionsError {
  MissingServerName
  InvalidAlpn
  InvalidVersionRange
  EarlyDataRequiresReplayPolicy
  IncompleteClientCertificate
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
  match (self.client_certificate, self.client_private_key) {
    (Some(certificate), Some(key)) if certificate.is_empty() || key.is_empty() =>
      return Err(IncompleteClientCertificate)
    (Some(_), None) | (None, Some(_)) => return Err(IncompleteClientCertificate)
    _ => ()
  }
  Ok(())
}

///|
/// Validates the complete client configuration. The endpoint-specific host
/// may be supplied by the URI when `server_name` was left unset.
pub fn TlsOptions::validate(self : TlsOptions) -> Result[Unit, TlsOptionsError] {
  match self.validate_common() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if self.verify_peer {
    match self.server_name {
      None => return Err(MissingServerName)
      Some(name) if name.is_empty() => return Err(MissingServerName)
      _ => ()
    }
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
/// Client-side validation is intentionally stricter than the compatibility
/// `validate` method: a client that skips hostname identity is an explicit
/// opt-in, while the default path always carries a usable SNI name.
pub fn TlsOptions::validate_client(
  self : TlsOptions,
) -> Result[Unit, TlsOptionsError] {
  match self.validate() {
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
  let copy = { ..self, verify_peer: false, server_name: Some("server"), }
  match copy.validate_common() {
    Ok(_) => Ok(())
    Err(error) => Err(error)
  }
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
pub(all) suberror TlsError {
  InvalidOptions(TlsOptionsError)
  VerificationFailed(String)
  HostnameMismatch
  Alert(Int)
  HandshakeFailed(String)
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
  transport : @transport.StreamConnection
  version : TlsVersion
  cipher_suite : String
  alpn : String?
  peer_identity : String?
  authenticated : Bool
}

///|
pub fn SecureConnection::new(
  transport : @transport.StreamConnection,
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
) -> Result[Bytes?, @transport.TransportError] {
  self.transport.read(max_bytes)
}

///|
pub async fn SecureConnection::write(
  self : SecureConnection,
  bytes : Bytes,
) -> Result[Unit, @transport.TransportError] {
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
  async fn client_handshake(Self, @transport.StreamConnection, TlsOptions) -> Result[
    SecureConnection,
    TlsError,
  ]
  async fn server_handshake(Self, @transport.StreamConnection, TlsOptions) -> Result[
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
  match options.validate() {
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
