///|
/// TLS 1.3 cipher suites that can produce QUIC packet-protection keys.
/// AES-128-GCM is the mandatory-to-implement QUIC v1 suite.
pub(all) enum QuicTlsCipherSuite {
  TlsAes128GcmSha256
  TlsAes256GcmSha384
} derive(Eq, Debug)

///|
/// Opaque directional QUIC packet keys. This type deliberately has no
/// `Debug` implementation so traffic secrets cannot be logged accidentally.
pub struct QuicPacketKeys {
  suite : QuicTlsCipherSuite
  secret : Bytes
  key : Bytes
  iv : Bytes
  hp : Bytes
}

///|
fn tls_concat_bytes(parts : Array[Bytes]) -> Bytes {
  let mut length = 0
  for part in parts {
    length += part.length()
  }
  let output = FixedArray::make(length, b'\x00')
  let mut offset = 0
  for part in parts {
    for byte in part {
      output[offset] = byte
      offset += 1
    }
  }
  output.unsafe_reinterpret_as_bytes()
}

///|
fn tls_u16_be(value : Int) -> Bytes {
  Bytes::from_array([((value >> 8) & 0xff).to_byte(), (value & 0xff).to_byte()])
}

///|
fn quic_hash_algorithm(suite : QuicTlsCipherSuite) -> @hkdf.HashAlg {
  match suite {
    TlsAes128GcmSha256 => Sha256
    TlsAes256GcmSha384 => Sha384
  }
}

///|
fn quic_key_length(suite : QuicTlsCipherSuite) -> Int {
  match suite {
    TlsAes128GcmSha256 => 16
    TlsAes256GcmSha384 => 32
  }
}

///|
fn quic_secret_length(suite : QuicTlsCipherSuite) -> Int {
  match suite {
    TlsAes128GcmSha256 => 32
    TlsAes256GcmSha384 => 48
  }
}

///|
fn quic_aead_algorithm(suite : QuicTlsCipherSuite) -> @aead.Algorithm {
  match suite {
    TlsAes128GcmSha256 => Aes128Gcm
    TlsAes256GcmSha384 => Aes256Gcm
  }
}

///|
fn tls13_expand_label(
  secret : Bytes,
  suite : QuicTlsCipherSuite,
  label : String,
  length : Int,
) -> Result[Bytes, TlsError] {
  if label.length() > 249 || length < 0 || length > 65535 {
    return Err(InvalidTrafficSecret)
  }
  let full_label = @utf8.encode("tls13 " + label)
  let info = tls_concat_bytes([
    tls_u16_be(length),
    Bytes::from_array([full_label.length().to_byte()]),
    full_label,
    b"\x00",
  ])
  let expanded : Result[Bytes, Error] = Ok(
    @hkdf.expand(quic_hash_algorithm(suite), secret, info, length),
  ) catch {
    error => Err(error)
  }
  match expanded {
    Ok(value) => Ok(value)
    Err(_) => Err(InvalidTrafficSecret)
  }
}

///|
/// Derives QUIC packet keys from a TLS 1.3 traffic secret (RFC 9001 section
/// 5.1). A traffic secret must match the hash length of its cipher suite.
pub fn derive_quic_packet_keys(
  traffic_secret : Bytes,
  suite? : QuicTlsCipherSuite = TlsAes128GcmSha256,
) -> Result[QuicPacketKeys, TlsError] {
  if traffic_secret.length() != quic_secret_length(suite) {
    return Err(InvalidTrafficSecret)
  }
  let key = match
    tls13_expand_label(
      traffic_secret,
      suite,
      "quic key",
      quic_key_length(suite),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let iv = match tls13_expand_label(traffic_secret, suite, "quic iv", 12) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let hp = match
    tls13_expand_label(traffic_secret, suite, "quic hp", quic_key_length(suite)) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({ suite, secret: traffic_secret, key, iv, hp, })
}

///|
/// Derives the client and server QUIC v1 Initial keys from the client's
/// Destination Connection ID (RFC 9001 section 5.2).
pub fn quic_v1_initial_keys(
  destination_connection_id : Bytes,
) -> Result[(QuicPacketKeys, QuicPacketKeys), TlsError] {
  if destination_connection_id.is_empty() ||
    destination_connection_id.length() > 20 {
    return Err(InvalidTrafficSecret)
  }
  let salt = b"\x38\x76\x2c\xf7\xf5\x59\x34\xb3\x4d\x17\x9a\xe6\xa4\xc8\x0c\xad\xcc\xbb\x7f\x0a"
  let initial_secret = @hkdf.extract(Sha256, salt, destination_connection_id)
  let client_secret = match
    tls13_expand_label(initial_secret, TlsAes128GcmSha256, "client in", 32) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let server_secret = match
    tls13_expand_label(initial_secret, TlsAes128GcmSha256, "server in", 32) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let client = match derive_quic_packet_keys(client_secret) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let server = match derive_quic_packet_keys(server_secret) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok((client, server))
}

///|
pub fn QuicPacketKeys::cipher_suite(
  self : QuicPacketKeys,
) -> QuicTlsCipherSuite {
  self.suite
}

///|
fn QuicPacketKeys::nonce(
  self : QuicPacketKeys,
  packet_number : Int64,
) -> Result[Bytes, TlsError] {
  if packet_number < 0L || packet_number > 0x3fffffffffffffffL {
    return Err(InvalidPacketNumber)
  }
  let output = FixedArray::make(12, b'\x00')
  for index in 0..<12 {
    let from_end = 11 - index
    let packet_byte = if from_end < 8 {
      ((packet_number >> (from_end * 8)) & 0xffL).to_byte()
    } else {
      b'\x00'
    }
    output[index] = (self.iv[index].to_int() ^ packet_byte.to_int()).to_byte()
  }
  Ok(output.unsafe_reinterpret_as_bytes())
}

///|
pub fn QuicPacketKeys::seal(
  self : QuicPacketKeys,
  packet_number : Int64,
  header : Bytes,
  plaintext : Bytes,
) -> Result[Bytes, TlsError] {
  let nonce = match self.nonce(packet_number) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let output : Result[Bytes, Error] = Ok(
    @aead.seal(
      quic_aead_algorithm(self.suite),
      self.key,
      nonce,
      header,
      plaintext,
    ),
  ) catch {
    error => Err(error)
  }
  match output {
    Ok(value) => Ok(value)
    Err(_) => Err(PacketProtectionFailed)
  }
}

///|
pub fn QuicPacketKeys::open(
  self : QuicPacketKeys,
  packet_number : Int64,
  header : Bytes,
  ciphertext : Bytes,
) -> Result[Bytes, TlsError] {
  let nonce = match self.nonce(packet_number) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let opened : Result[Bytes, Error] = Ok(
    @aead.open(
      quic_aead_algorithm(self.suite),
      self.key,
      nonce,
      header,
      ciphertext,
    ),
  ) catch {
    error => Err(error)
  }
  match opened {
    Ok(value) => Ok(value)
    Err(_) => Err(PacketAuthenticationFailed)
  }
}

///|
pub fn QuicPacketKeys::header_protection_mask(
  self : QuicPacketKeys,
  sample : Bytes,
) -> Result[Bytes, TlsError] {
  if sample.length() != 16 {
    return Err(PacketProtectionFailed)
  }
  let block : Result[Bytes, Error] = Ok(
    @aead.aes_block_encrypt(self.hp, sample),
  ) catch {
    error => Err(error)
  }
  match block {
    Ok(value) => Ok(value[:5].to_owned())
    Err(_) => Err(PacketProtectionFailed)
  }
}
