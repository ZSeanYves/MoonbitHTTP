///|
priv type OpenSsl

///|
#borrow(host, roots, crls, ocsp_response, certificate, private_key, alpn)
extern "C" fn openssl_new(
  symbols : @packet_crypto.OpenSslSymbols,
  server : Bool,
  verify : Bool,
  system_roots : Bool,
  min_version : Int32,
  max_version : Int32,
  host : Bytes,
  numeric_host : Bool,
  roots : Bytes,
  crls : Bytes,
  require_crl : Bool,
  require_ocsp : Bool,
  ocsp_response : Bytes,
  certificate : Bytes,
  private_key : Bytes,
  alpn : Bytes,
) -> OpenSsl = "moon_http_tls_new"

///|
/// Verify a stapled OCSP response captured by the native TLS session.
#borrow(self)
extern "C" fn OpenSsl::check_ocsp(self : OpenSsl, require : Bool) -> Bool = "moon_http_tls_check_ocsp"

///|
#borrow(self)
extern "C" fn OpenSsl::ready(self : OpenSsl) -> Bool = "moon_http_tls_ready"

///|
#borrow(self)
extern "C" fn OpenSsl::available(self : OpenSsl) -> Bool = "moon_http_tls_available"

///|
#borrow(self)
extern "C" fn OpenSsl::close(self : OpenSsl) -> Unit = "moon_http_tls_close"

///|
#borrow(self)
extern "C" fn OpenSsl::send_close_notify(self : OpenSsl) -> Bool = "moon_http_tls_send_close_notify"

///|
#borrow(self)
extern "C" fn OpenSsl::error_code(self : OpenSsl) -> UInt64 = "moon_http_tls_error_code"

///|
#borrow(self)
extern "C" fn OpenSsl::verify_code(self : OpenSsl) -> Int64 = "moon_http_tls_verify_code"

///|
#borrow(self)
extern "C" fn OpenSsl::error_message(self : OpenSsl) -> Bytes = "moon_http_tls_error_message"

///|
#borrow(self)
extern "C" fn OpenSsl::handshake(self : OpenSsl) -> Int32 = "moon_http_tls_handshake"

///|
#borrow(self, bytes)
extern "C" fn OpenSsl::feed(self : OpenSsl, bytes : Bytes) -> Int32 = "moon_http_tls_feed"

///|
#borrow(self)
extern "C" fn OpenSsl::drain(self : OpenSsl) -> Bytes = "moon_http_tls_drain"

///|
#borrow(self, bytes, count)
extern "C" fn OpenSsl::read(
  self : OpenSsl,
  bytes : FixedArray[Byte],
  count : Ref[Int32],
) -> Int32 = "moon_http_tls_read"

///|
#borrow(self, bytes, count)
extern "C" fn OpenSsl::write(
  self : OpenSsl,
  bytes : Bytes,
  offset : Int32,
  length : Int32,
  count : Ref[Int32],
) -> Int32 = "moon_http_tls_write"

///|
#borrow(self)
extern "C" fn OpenSsl::version(self : OpenSsl) -> Int32 = "moon_http_tls_version"

///|
#borrow(self)
extern "C" fn OpenSsl::cipher(self : OpenSsl) -> Bytes = "moon_http_tls_cipher"

///|
#borrow(self)
extern "C" fn OpenSsl::alpn(self : OpenSsl) -> Bytes = "moon_http_tls_alpn"

///|
#borrow(self)
extern "C" fn OpenSsl::peer_authenticated(self : OpenSsl) -> Bool = "moon_http_tls_peer_authenticated"

///|
#borrow(self)
extern "C" fn OpenSsl::peer_certificate_parts(
  self : OpenSsl,
) -> FixedArray[Bytes] = "moon_http_tls_peer_certificate"

///|
fn OpenSsl::verified_certificate(
  self : OpenSsl,
) -> Result[@transport.VerifiedClientCertificate, @transport.TlsError] {
  let parts = self.peer_certificate_parts()
  guard parts.length() > 0 && parts[0].length() == 32 else {
    return Err(VerificationFailed("unable to read verified client certificate"))
  }
  let names : Array[@transport.CertificateName] = []
  for index in 1..<parts.length() {
    let part = parts[index]
    if part.is_empty() {
      continue
    }
    let value = part[1:]
    if part[0] == b'\x07' {
      guard value.length() == 4 || value.length() == 16 else {
        return Err(VerificationFailed("invalid certificate IP subjectAltName"))
      }
      names.push(IpAddressBytes(value.to_owned()))
    } else {
      guard value.length() > 0 &&
        !value.iter().any(byte => byte <= b'\x1f' || byte >= b'\x7f') else {
        return Err(VerificationFailed("invalid certificate IA5 subjectAltName"))
      }
      let text = @utf8.decode_lossy(value)
      match part[0] {
        b'\x01' => names.push(EmailName(text))
        b'\x02' => names.push(DnsName(text))
        b'\x06' => names.push(UriName(text))
        _ => ()
      }
    }
  }
  Ok({ sha256: parts[0], subject_alt_names: ReadOnlyArray::from_array(names), })
}
