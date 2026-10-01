///|
priv type OpenSsl

///|
#borrow(host, roots, certificate, private_key, alpn)
extern "C" fn openssl_new(
  server : Bool,
  verify : Bool,
  system_roots : Bool,
  min_version : Int,
  max_version : Int,
  host : Bytes,
  numeric_host : Bool,
  roots : Bytes,
  certificate : Bytes,
  private_key : Bytes,
  alpn : Bytes,
) -> OpenSsl = "moon_http_tls_new"

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
extern "C" fn OpenSsl::error_code(self : OpenSsl) -> UInt64 = "moon_http_tls_error_code"

///|
#borrow(self)
extern "C" fn OpenSsl::verify_code(self : OpenSsl) -> Int64 = "moon_http_tls_verify_code"

///|
#borrow(self)
extern "C" fn OpenSsl::error_message(self : OpenSsl) -> Bytes = "moon_http_tls_error_message"

///|
#borrow(self)
extern "C" fn OpenSsl::handshake(self : OpenSsl) -> Int = "moon_http_tls_handshake"

///|
#borrow(self, bytes)
extern "C" fn OpenSsl::feed(self : OpenSsl, bytes : Bytes) -> Int = "moon_http_tls_feed"

///|
#borrow(self)
extern "C" fn OpenSsl::drain(self : OpenSsl) -> Bytes = "moon_http_tls_drain"

///|
#borrow(self, bytes, count)
extern "C" fn OpenSsl::read(
  self : OpenSsl,
  bytes : FixedArray[Byte],
  count : Ref[Int],
) -> Int = "moon_http_tls_read"

///|
#borrow(self, bytes, count)
extern "C" fn OpenSsl::write(
  self : OpenSsl,
  bytes : Bytes,
  offset : Int,
  length : Int,
  count : Ref[Int],
) -> Int = "moon_http_tls_write"

///|
#borrow(self)
extern "C" fn OpenSsl::version(self : OpenSsl) -> Int = "moon_http_tls_version"

///|
#borrow(self)
extern "C" fn OpenSsl::cipher(self : OpenSsl) -> Bytes = "moon_http_tls_cipher"

///|
#borrow(self)
extern "C" fn OpenSsl::alpn(self : OpenSsl) -> Bytes = "moon_http_tls_alpn"

///|
#borrow(self)
extern "C" fn OpenSsl::peer_authenticated(self : OpenSsl) -> Bool = "moon_http_tls_peer_authenticated"
