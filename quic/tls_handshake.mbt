///|
/// TLS-side framing for the driver's already ordered CryptoData actions.
/// The datagram driver retains responsibility for retransmission and CRYPTO
/// reassembly; each TLS encryption level has its own bounded message decoder.
pub struct QuicHandshakeInput {
  priv initial : @tls.QuicHandshakeDecoder
  priv handshake : @tls.QuicHandshakeDecoder
  priv application : @tls.QuicHandshakeDecoder
}

///|
pub fn QuicHandshakeInput::new(
  max_bytes_per_level? : Int = 1024 * 1024,
  max_messages_per_level? : Int = 256,
) -> Result[QuicHandshakeInput, QuicError] {
  let initial = match
    @tls.QuicHandshakeDecoder::new(
      QuicInitial,
      max_bytes=max_bytes_per_level,
      max_messages=max_messages_per_level,
    ) {
    Ok(value) => value
    Err(error) => return Err(Tls(error))
  }
  let handshake = match
    @tls.QuicHandshakeDecoder::new(
      QuicHandshake,
      max_bytes=max_bytes_per_level,
      max_messages=max_messages_per_level,
    ) {
    Ok(value) => value
    Err(error) => return Err(Tls(error))
  }
  let application = match
    @tls.QuicHandshakeDecoder::new(
      QuicApplication,
      max_bytes=max_bytes_per_level,
      max_messages=max_messages_per_level,
    ) {
    Ok(value) => value
    Err(error) => return Err(Tls(error))
  }
  Ok({ initial, handshake, application, })
}

///|
pub fn QuicHandshakeInput::feed(
  self : QuicHandshakeInput,
  space : PacketNumberSpace,
  offset : Int64,
  bytes : Bytes,
) -> Result[Array[@transport.QuicHandshakeMessage], QuicError] {
  let decoder = match space {
    Initial => self.initial
    Handshake => self.handshake
    Application => self.application
  }
  match decoder.feed(offset, bytes) {
    Ok(value) => Ok(value)
    Err(error) => Err(Tls(error))
  }
}

///|
pub fn QuicHandshakeInput::finish_level(
  self : QuicHandshakeInput,
  space : PacketNumberSpace,
) -> Result[Unit, QuicError] {
  let decoder = match space {
    Initial => self.initial
    Handshake => self.handshake
    Application => self.application
  }
  match decoder.finish() {
    Ok(value) => Ok(value)
    Err(error) => Err(Tls(error))
  }
}

///|
/// Accepts a trusted TLS provider's directional traffic-secret callback.
/// Initial keys are derived from the connection ID, never installed by TLS.
/// Secrets are installed once at their encryption level; this method cannot be
/// used as a key-update shortcut or as a handshake-completion signal.
pub fn QuicDatagramDriver::install_traffic_secret(
  self : QuicDatagramDriver,
  level : @transport.QuicEncryptionLevel,
  direction : @transport.QuicSecretDirection,
  secret : Bytes,
  suite? : @transport.QuicTlsCipherSuite = TlsAes128GcmSha256,
) -> Result[Unit, QuicError] {
  if self.state() != Handshaking {
    return Err(
      Unsupported("TLS traffic secrets require a handshaking connection"),
    )
  }
  let (previous, companion) = match (level, direction) {
    (QuicInitial, _) =>
      return Err(Unsupported("Initial keys are derived from the connection ID"))
    (QuicHandshake, QuicReadSecret) =>
      (self.handshake_receive_keys, self.handshake_send_keys)
    (QuicHandshake, QuicWriteSecret) =>
      (self.handshake_send_keys, self.handshake_receive_keys)
    (QuicApplication, QuicReadSecret) =>
      (self.application_receive_keys, self.application_send_keys)
    (QuicApplication, QuicWriteSecret) =>
      (self.application_send_keys, self.application_receive_keys)
  }
  if previous is Some(_) {
    return Err(Unsupported("TLS traffic secret is already installed"))
  }
  if companion is Some(keys) && keys.cipher_suite() != suite {
    return Err(InvalidPacket("TLS directional cipher suites differ"))
  }
  if level == QuicApplication {
    match (self.handshake_send_keys, self.handshake_receive_keys) {
      (Some(send), Some(receive)) =>
        if send.cipher_suite() != suite || receive.cipher_suite() != suite {
          return Err(
            InvalidPacket("TLS cipher suite changed across encryption levels"),
          )
        }
      _ => return Err(Unsupported("application secrets require handshake keys"))
    }
  }
  let keys = match @tls.derive_quic_packet_keys(secret, suite~) {
    Ok(value) => value
    Err(error) => return Err(Tls(error))
  }
  match (level, direction) {
    (QuicHandshake, QuicReadSecret) => self.handshake_receive_keys = Some(keys)
    (QuicHandshake, QuicWriteSecret) => self.handshake_send_keys = Some(keys)
    (QuicApplication, QuicReadSecret) => {
      let next = match keys.next_application_keys() {
        Ok(value) => value
        Err(error) => return Err(Tls(error))
      }
      self.application_receive_keys = Some(keys)
      self.key_update.next_receive = Some(next)
    }
    (QuicApplication, QuicWriteSecret) =>
      self.application_send_keys = Some(keys)
    (QuicInitial, _) => ()
  }
  Ok(())
}
