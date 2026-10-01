///|
/// TLS 1.3 cipher suites that can produce QUIC packet-protection keys.
/// AES-128-GCM is the mandatory-to-implement QUIC v1 suite.
pub(all) enum QuicTlsCipherSuite {
  TlsAes128GcmSha256
  TlsAes256GcmSha384
} derive(Eq, Debug)

///|
/// Encryption levels have independent CRYPTO byte streams. Early data carries
/// application data only and deliberately has no handshake level here.
pub(all) enum QuicEncryptionLevel {
  QuicInitial
  QuicHandshake
  QuicApplication
} derive(Eq, Debug)

///|
pub(all) enum QuicSecretDirection {
  QuicReadSecret
  QuicWriteSecret
} derive(Eq, Debug)

///|
/// A complete, bounded TLS Handshake message, including its four-byte header.
/// QUIC carries these bytes directly, without TLS records.
pub(all) struct QuicHandshakeMessage {
  level : QuicEncryptionLevel
  message_type : Int
  encoded : Bytes
} derive(Eq, Debug)

///|
/// Provider results intentionally do not implement Debug: traffic secrets must
/// not appear in logs. Completion is a claim made by a trusted TLS provider,
/// after verifying the peer Finished and sending its own Finished, not evidence
/// derived merely from installing application keys. Transport parameters must
/// be authenticated by that same handshake before they affect QUIC state.
pub(all) enum QuicTlsEvent {
  HandshakeBytes(QuicEncryptionLevel, Bytes)
  TrafficSecret(
    QuicEncryptionLevel,
    QuicSecretDirection,
    QuicTlsCipherSuite,
    Bytes
  )
  HandshakeComplete(String, Bytes)
}

///|
/// Interface for an actual QUIC-capable TLS 1.3 engine. Implementations own the
/// TLS transcript, key exchange, certificate/hostname/time verification, ALPN,
/// QUIC transport-parameter extension and Finished verification. The application
/// injects credentials and trust through options; no implicit trust is allowed.
/// A message decoder and a traffic-secret callback alone do not implement this
/// contract. The current distribution has no concrete implementation.
pub(open) trait QuicTlsProvider {
  fn start(Self, TlsOptions, Bytes) -> Result[Array[QuicTlsEvent], TlsError]
  fn receive_handshake(Self, QuicHandshakeMessage) -> Result[
    Array[QuicTlsEvent],
    TlsError,
  ]
}
