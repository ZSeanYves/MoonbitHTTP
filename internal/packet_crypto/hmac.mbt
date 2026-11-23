///|
/// RFC 5869 HKDF-Extract with SHA-256 is HMAC-SHA256(salt, input).
pub fn hmac_sha256(key : Bytes, input : Bytes) -> Bytes raise {
  extract(key, input)
}
