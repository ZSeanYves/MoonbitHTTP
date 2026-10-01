///|
pub const QUIC_VERSION_1 : Int = 1

///|
/// QUIC Version Negotiation packets use version zero on the wire.
pub const QUIC_VERSION_NEGOTIATION : Int = 0

///|
pub const QUIC_MAX_CONNECTION_ID : Int = 20

///|
pub const QUIC_MAX_PACKET_SIZE : Int = 65527

///|
pub const QUIC_MAX_VARINT : Int64 = 0x3fffffffffffffffL

///|
/// RFC 9001 section 6.6 AES-GCM usage limits.  These values are kept in
/// packet units so every key phase can be accounted independently.
pub const QUIC_AEAD_CONFIDENTIALITY_LIMIT : Int64 = 1L << 23

///|
pub const QUIC_AEAD_INTEGRITY_LIMIT : Int64 = 1L << 52

///|
pub const QUIC_KEY_UPDATE_ERROR : Int64 = 0x0eL

///|
pub const QUIC_AEAD_LIMIT_REACHED : Int64 = 0x0fL

///|
pub(all) suberror QuicError {
  NeedMoreInput
  UnexpectedEof(String)
  Malformed(String)
  NonCanonicalVarInt
  VarIntOverflow
  LimitExceeded(String, Int)
  InvalidPacket(String)
  InvalidFrame(String)
  InvalidTransportParameter(String)
  Protocol(Int64, String)
  FlowControl(Int64, String)
  AmplificationBlocked
  StreamClosed(Int64)
  ConnectionClosed(Int64, String)
  Policy(@transport.PolicyError)
  Transport(@transport.TransportError)
  Entropy(@transport.EntropyError)
  Tls(@transport.TlsError)
  VersionNegotiation(Array[Int])
  Unsupported(String)
} derive(Eq, Debug)

///|
pub(all) struct QuicLimits {
  max_packet_size : Int
  max_datagram_size : Int
  max_frame_payload : Int
  max_ack_ranges : Int
  max_crypto_bytes : Int
  max_streams : Int
  max_connection_data : Int64
  max_stream_data : Int64
} derive(Eq, Debug)

///|
pub fn QuicLimits::defaults() -> QuicLimits {
  {
    max_packet_size: 1350,
    max_datagram_size: 65527,
    max_frame_payload: 16 * 1024 * 1024,
    max_ack_ranges: 256,
    max_crypto_bytes: 1024 * 1024,
    max_streams: 100,
    max_connection_data: 16 * 1024 * 1024L,
    max_stream_data: 1024 * 1024L,
  }
}

///|
pub fn QuicLimits::validate(self : QuicLimits) -> Result[Unit, QuicError] {
  let values : Array[(String, Int, Bool)] = [
    ("max_packet_size", self.max_packet_size, false),
    ("max_datagram_size", self.max_datagram_size, false),
    ("max_frame_payload", self.max_frame_payload, true),
    ("max_ack_ranges", self.max_ack_ranges, false),
    ("max_crypto_bytes", self.max_crypto_bytes, true),
    ("max_streams", self.max_streams, false),
  ]
  for entry in values {
    let (name, value, zero_ok) = entry
    if value < 0 || (!zero_ok && value == 0) {
      return Err(LimitExceeded(name, value))
    }
  }
  if self.max_connection_data < 0L || self.max_connection_data > QUIC_MAX_VARINT {
    return Err(LimitExceeded("max_connection_data", @int.MAX_VALUE))
  }
  if self.max_stream_data < 0L || self.max_stream_data > QUIC_MAX_VARINT {
    return Err(LimitExceeded("max_stream_data", @int.MAX_VALUE))
  }
  if self.max_stream_data > @int.MAX_VALUE.to_int64() {
    return Err(LimitExceeded("max_stream_data", @int.MAX_VALUE))
  }
  if self.max_packet_size > self.max_datagram_size {
    return Err(LimitExceeded("max_packet_size", self.max_packet_size))
  }
  Ok(())
}
