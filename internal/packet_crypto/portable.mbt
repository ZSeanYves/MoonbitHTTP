///|
pub fn expand(
  sha384 : Bool,
  key : Bytes,
  info : Bytes,
  size : Int32,
) -> Bytes raise {
  @hkdf.expand(if sha384 { Sha384 } else { Sha256 }, key, info, size)
}

///|
// Match the fallible provider contract shared with Native EVP.
#warnings("-unused_error_type")
pub fn extract(salt : Bytes, input : Bytes) -> Bytes raise {
  @hkdf.extract(Sha256, salt, input)
}

///|
pub fn seal(
  key : Bytes,
  nonce : Bytes,
  aad : Bytes,
  input : Bytes,
) -> Bytes raise {
  @aead.seal(
    if key.length() == 32 {
      Aes256Gcm
    } else {
      Aes128Gcm
    },
    key,
    nonce,
    aad,
    input,
  )
}

///|
pub fn open(
  key : Bytes,
  nonce : Bytes,
  aad : Bytes,
  input : Bytes,
) -> Bytes raise {
  @aead.open(
    if key.length() == 32 {
      Aes256Gcm
    } else {
      Aes128Gcm
    },
    key,
    nonce,
    aad,
    input,
  )
}

///|
pub fn aes_block(key : Bytes, input : Bytes) -> Bytes raise {
  @aead.aes_block_encrypt(key, input)
}
