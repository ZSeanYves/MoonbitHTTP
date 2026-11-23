///|
priv suberror PacketCryptoFailure

///|
#borrow(key, param, out)
extern "C" fn kdf(
  expand : Bool,
  sha384 : Bool,
  key : Bytes,
  param : Bytes,
  out : FixedArray[Byte],
) -> Bool = "moon_http_packet_kdf"

///|
#borrow(key, iv, aad, input, out)
extern "C" fn crypt(
  mode : Int32,
  key : Bytes,
  iv : Bytes,
  aad : Bytes,
  input : Bytes,
  out : FixedArray[Byte],
) -> Bool = "moon_http_packet_cipher"

///|
#borrow(buffer)
pub extern "C" fn random_fill(buffer : FixedArray[Byte]) -> Bool = "moon_http_random_fill"

///|
pub fn expand(
  sha384 : Bool,
  key : Bytes,
  info : Bytes,
  size : Int32,
) -> Bytes raise {
  guard size > 0 && size <= 48 else { raise PacketCryptoFailure }
  let out = FixedArray::make(size, b'\x00')
  guard kdf(true, sha384, key, info, out) else { raise PacketCryptoFailure }
  out.unsafe_reinterpret_as_bytes()
}

///|
pub fn extract(salt : Bytes, input : Bytes) -> Bytes raise {
  let out = FixedArray::make(32, b'\x00')
  guard kdf(false, false, input, salt, out) else { raise PacketCryptoFailure }
  out.unsafe_reinterpret_as_bytes()
}

///|
pub fn seal(
  key : Bytes,
  nonce : Bytes,
  aad : Bytes,
  input : Bytes,
) -> Bytes raise {
  guard input.length() <= 0x7fffffff - 16 else { raise PacketCryptoFailure }
  let out = FixedArray::make(input.length() + 16, b'\x00')
  guard crypt(1, key, nonce, aad, input, out) else { raise PacketCryptoFailure }
  out.unsafe_reinterpret_as_bytes()
}

///|
pub fn open(
  key : Bytes,
  nonce : Bytes,
  aad : Bytes,
  input : Bytes,
) -> Bytes raise {
  guard input.length() >= 16 else { raise PacketCryptoFailure }
  let out = FixedArray::make(input.length() - 16, b'\x00')
  guard crypt(0, key, nonce, aad, input, out) else { raise PacketCryptoFailure }
  out.unsafe_reinterpret_as_bytes()
}

///|
pub fn aes_block(key : Bytes, input : Bytes) -> Bytes raise {
  let out = FixedArray::make(16, b'\x00')
  guard crypt(2, key, b"", b"", input, out) else { raise PacketCryptoFailure }
  out.unsafe_reinterpret_as_bytes()
}

///|
#external
pub type OpenSslSymbols

///|
pub extern "C" fn openssl_symbols() -> OpenSslSymbols = "moon_http_openssl_symbols"
