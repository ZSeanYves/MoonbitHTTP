///|
/// White-box OCSP fixture generator used only by the Native TLS wbtest suite.
#borrow(subject, issuer, private_key)
pub extern "C" fn test_ocsp(
  subject : Bytes,
  issuer : Bytes,
  private_key : Bytes,
  status : Int,
  this_offset : Int,
  next_offset : Int,
  omit_next : Bool,
  corrupt_signature : Bool,
) -> Bytes = "moon_http_test_ocsp"

///|
/// White-box CRL fixture generator used only by the Native TLS wbtest suite.
#borrow(issuer, private_key, revoked)
pub extern "C" fn test_crl(
  issuer : Bytes,
  private_key : Bytes,
  revoked : Bytes,
  this_offset : Int,
  next_offset : Int,
) -> Bytes = "moon_http_test_crl"
