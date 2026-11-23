///|
/// White-box OCSP fixture generator used only by the Native TLS wbtest suite.
#borrow(subject, issuer, private_key)
extern "C" fn test_ocsp_with_symbols(
  symbols : @packet_crypto.OpenSslSymbols,
  subject : Bytes,
  issuer : Bytes,
  private_key : Bytes,
  status : Int32,
  this_offset : Int32,
  next_offset : Int32,
  omit_next : Bool,
  corrupt_signature : Bool,
) -> Bytes = "moon_http_test_ocsp"

///|
pub fn test_ocsp(
  subject : Bytes,
  issuer : Bytes,
  private_key : Bytes,
  status : Int32,
  this_offset : Int32,
  next_offset : Int32,
  omit_next : Bool,
  corrupt_signature : Bool,
) -> Bytes {
  test_ocsp_with_symbols(
    @packet_crypto.openssl_symbols(),
    subject,
    issuer,
    private_key,
    status,
    this_offset,
    next_offset,
    omit_next,
    corrupt_signature,
  )
}

///|
/// White-box CRL fixture generator used only by the Native TLS wbtest suite.
#borrow(issuer, private_key, revoked)
extern "C" fn test_crl_with_symbols(
  symbols : @packet_crypto.OpenSslSymbols,
  issuer : Bytes,
  private_key : Bytes,
  revoked : Bytes,
  this_offset : Int32,
  next_offset : Int32,
) -> Bytes = "moon_http_test_crl"

///|
pub fn test_crl(
  issuer : Bytes,
  private_key : Bytes,
  revoked : Bytes,
  this_offset : Int32,
  next_offset : Int32,
) -> Bytes {
  test_crl_with_symbols(
    @packet_crypto.openssl_symbols(),
    issuer,
    private_key,
    revoked,
    this_offset,
    next_offset,
  )
}
