///|
/// Incremental TLS Handshake framing for one already-reassembled CRYPTO stream.
/// QUIC handles loss/reordering; this decoder handles message fragmentation and
/// coalescing. Limits bound both retained memory and work over the stream's
/// lifetime. It never validates certificates or declares a handshake complete.
pub struct QuicHandshakeDecoder {
  priv level : QuicEncryptionLevel
  priv max_bytes : Int
  priv max_messages : Int
  priv buffer : Array[Byte]
  priv mut received : Int
  priv mut messages : Int
  priv mut finished : Bool
  priv mut failure : TlsError?
}

///|
pub fn QuicHandshakeDecoder::new(
  level : QuicEncryptionLevel,
  max_bytes? : Int = 1024 * 1024,
  max_messages? : Int = 256,
) -> Result[QuicHandshakeDecoder, TlsError] {
  if max_bytes < 4 || max_messages < 1 {
    return Err(HandshakeFailed("invalid QUIC handshake limits"))
  }
  Ok({
    level,
    max_bytes,
    max_messages,
    buffer: [],
    received: 0,
    messages: 0,
    finished: false,
    failure: None,
  })
}

///|
fn quic_handshake_type_allowed(level : QuicEncryptionLevel, typ : Int) -> Bool {
  // RFC 9001 §§4, 6: KeyUpdate and EndOfEarlyData are never sent in QUIC.
  // Post-handshake authentication is unsupported; only session tickets remain.
  match level {
    QuicInitial => typ == 1 || typ == 2
    QuicHandshake =>
      typ == 8 || typ == 11 || typ == 13 || typ == 15 || typ == 20
    QuicApplication => typ == 4
  }
}

///|
pub fn QuicHandshakeDecoder::feed(
  self : QuicHandshakeDecoder,
  offset : Int64,
  bytes : Bytes,
) -> Result[Array[QuicHandshakeMessage], TlsError] {
  if self.failure is Some(error) {
    return Err(error)
  }
  if self.finished {
    return Err(HandshakeFailed("QUIC handshake level is finished"))
  }
  let result = self.feed_contiguous(offset, bytes)
  if result is Err(error) {
    self.failure = Some(error)
    self.buffer.clear()
  }
  result
}

///|
fn QuicHandshakeDecoder::feed_contiguous(
  self : QuicHandshakeDecoder,
  offset : Int64,
  bytes : Bytes,
) -> Result[Array[QuicHandshakeMessage], TlsError] {
  if offset != self.received.to_int64() {
    return Err(HandshakeFailed("non-contiguous QUIC handshake input"))
  }
  if bytes.length() > self.max_bytes - self.received {
    return Err(HandshakeFailed("QUIC handshake byte limit exceeded"))
  }
  let output : Array[QuicHandshakeMessage] = []
  for byte in bytes {
    self.buffer.push(byte)
    self.received += 1
    if self.buffer.length() < 4 {
      continue
    }
    let typ = self.buffer[0].to_int()
    if !quic_handshake_type_allowed(self.level, typ) {
      return Err(Alert(10))
    }
    let body_length = (self.buffer[1].to_int() << 16) |
      (self.buffer[2].to_int() << 8) |
      self.buffer[3].to_int()
    let total_length = body_length + 4
    if total_length > self.max_bytes {
      return Err(HandshakeFailed("QUIC handshake message limit exceeded"))
    }
    if self.buffer.length() == total_length {
      if self.messages >= self.max_messages {
        return Err(HandshakeFailed("QUIC handshake message count exceeded"))
      }
      output.push({
        level: self.level,
        message_type: typ,
        encoded: Bytes::from_array(self.buffer),
      })
      self.messages += 1
      self.buffer.clear()
    }
  }
  Ok(output)
}

///|
/// Verify a CRYPTO level boundary before keys for that level are discarded.
/// A partial message cannot carry over into a different encryption level.
pub fn QuicHandshakeDecoder::finish(
  self : QuicHandshakeDecoder,
) -> Result[Unit, TlsError] {
  if self.failure is Some(error) {
    return Err(error)
  }
  if !self.buffer.is_empty() {
    let error : TlsError = HandshakeFailed("truncated QUIC handshake message")
    self.failure = Some(error)
    self.buffer.clear()
    return Err(error)
  }
  self.finished = true
  Ok(())
}
