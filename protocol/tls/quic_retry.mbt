///|
/// QUIC v1 Retry integrity protection (RFC 9001 section 5.8).
///
/// Retry packets are not protected with packet keys.  Instead, the fixed
/// version-1 key and nonce authenticate the Original Destination Connection
/// ID together with the complete Retry packet up to (excluding) its tag.
/// Keeping this primitive in the TLS package prevents the transport driver
/// from accidentally substituting an Initial traffic secret.
pub fn quic_retry_integrity_tag(
  original_destination_connection_id : Bytes,
  retry_without_tag : Bytes,
) -> Result[Bytes, TlsError] {
  if original_destination_connection_id.length() > 20 {
    return Err(InvalidTrafficSecret)
  }
  let pseudo = FixedArray::make(
    1 + original_destination_connection_id.length() + retry_without_tag.length(),
    b'\x00',
  )
  pseudo[0] = original_destination_connection_id.length().to_byte()
  for index, byte in original_destination_connection_id {
    pseudo[index + 1] = byte
  }
  for index, byte in retry_without_tag {
    pseudo[index + 1 + original_destination_connection_id.length()] = byte
  }
  let key = b"\xbe\x0c\x69\x0b\x9f\x66\x57\x5a\x1d\x76\x6b\x54\xe3\x68\xc8\x4e"
  let nonce = b"\x46\x15\x99\xd3\x5d\x63\x2b\xf2\x23\x98\x25\xbb"
  let result : Result[Bytes, Error] = Ok(
    @aead.seal(Aes128Gcm, key, nonce, pseudo.unsafe_reinterpret_as_bytes(), b""),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(value) =>
      if value.length() < 16 {
        Err(PacketProtectionFailed)
      } else {
        Ok(value[value.length() - 16:].to_owned())
      }
    Err(_) => Err(PacketProtectionFailed)
  }
}

///|
pub fn quic_verify_retry_integrity(
  original_destination_connection_id : Bytes,
  retry_without_tag : Bytes,
  tag : Bytes,
) -> Result[Unit, TlsError] {
  if tag.length() != 16 {
    return Err(PacketAuthenticationFailed)
  }
  let expected = match
    quic_retry_integrity_tag(
      original_destination_connection_id, retry_without_tag,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if expected != tag {
    return Err(PacketAuthenticationFailed)
  }
  Ok(())
}
