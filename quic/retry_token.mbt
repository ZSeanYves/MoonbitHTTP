///|
/// Stateless Retry address-validation tokens.
///
/// The server-only HMAC key binds the source endpoint, original DCID,
/// Retry SCID, client SCID, issuance time and a fresh 128-bit nonce.
pub struct QuicRetryTokenManager {
  priv secret : Bytes
  priv lifetime_ms : Int64
}

///|
/// Opaque proof of a validated Retry token. Only `validate_initial` can create
/// this value; the driver checks its endpoint, CIDs and expiry before use.
pub struct QuicRetryContext {
  priv endpoint : @types.Endpoint
  priv original_destination : ConnectionId
  priv retry_source : ConnectionId
  priv client_source : ConnectionId
  priv issued_at_ms : Int64
  priv lifetime_ms : Int64
  priv token : Bytes
}

///|
let retry_token_magic : Bytes = b"QRT2"

///|
let retry_token_max_length : Int = 512

///|
let retry_token_max_endpoint_length : Int = 256

///|
fn retry_token_u16(value : Int) -> Bytes {
  Bytes::from_array([((value >> 8) & 0xff).to_byte(), (value & 0xff).to_byte()])
}

///|
fn retry_token_u64(value : Int64) -> Bytes {
  let output = FixedArray::make(8, b'\x00')
  for index in 0..<8 {
    output[index] = ((value >> ((7 - index) * 8)) & 0xffL).to_byte()
  }
  output.unsafe_reinterpret_as_bytes()
}

///|
fn retry_token_join(parts : Array[Bytes]) -> Bytes {
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
fn retry_token_equal(left : Bytes, right : Bytes) -> Bool {
  if left.length() != right.length() {
    return false
  }
  let mut difference = 0
  for index in 0..<left.length() {
    difference = difference | (left[index].to_int() ^ right[index].to_int())
  }
  difference == 0
}

///|
fn retry_token_cid_part(cid : ConnectionId) -> Bytes {
  let bytes = cid.bytes()
  retry_token_join([Bytes::from_array([bytes.length().to_byte()]), bytes])
}

///|
fn retry_token_read_cid(
  body : Bytes,
  cursor : Int,
) -> Result[(ConnectionId, Int), QuicError] {
  if cursor >= body.length() {
    return Err(InvalidPacket("Retry token connection ID length is missing"))
  }
  let length = body[cursor].to_int()
  let start = cursor + 1
  let end = start + length
  if length > QUIC_MAX_CONNECTION_ID || end > body.length() {
    return Err(InvalidPacket("Retry token connection ID is malformed"))
  }
  match ConnectionId::new(body[start:end].to_owned()) {
    Ok(cid) => Ok((cid, end))
    Err(error) => Err(error)
  }
}

///|
pub fn QuicRetryTokenManager::new(
  secret : Bytes,
  lifetime_ms? : Int64 = 30000L,
) -> Result[QuicRetryTokenManager, QuicError] {
  if secret.length() != 32 || lifetime_ms <= 0L {
    return Err(InvalidPacket("Retry token secret or lifetime is invalid"))
  }
  Ok({ secret, lifetime_ms, })
}

///|
/// Issues a token using explicit Clock and Entropy capabilities. The clock
/// must share a monotonic time domain with validation and driver events.
pub fn[C : @transport.Clock, E : @transport.Entropy] QuicRetryTokenManager::issue(
  self : QuicRetryTokenManager,
  endpoint : @types.Endpoint,
  original_destination : ConnectionId,
  retry_source : ConnectionId,
  client_source : ConnectionId,
  clock : C,
  entropy : E,
) -> Result[Bytes, QuicError] {
  let now_ms = @transport.Clock::monotonic_millis(clock)
  if now_ms < 0L ||
    retry_source.bytes().is_empty() ||
    retry_source == original_destination {
    return Err(InvalidPacket("Retry token issuance inputs are invalid"))
  }
  let binding = @utf8.encode(endpoint.scheme() + "://" + endpoint.authority())
  if binding.length() > retry_token_max_endpoint_length {
    return Err(
      LimitExceeded("Retry token endpoint", retry_token_max_endpoint_length),
    )
  }
  let nonce = FixedArray::make(16, b'\x00')
  match @transport.Entropy::fill(entropy, nonce) {
    Ok(_) => ()
    Err(error) => return Err(Entropy(error))
  }
  let body = retry_token_join([
    retry_token_magic,
    retry_token_u64(now_ms),
    retry_token_u16(binding.length()),
    binding,
    retry_token_cid_part(original_destination),
    retry_token_cid_part(retry_source),
    retry_token_cid_part(client_source),
    nonce.unsafe_reinterpret_as_bytes(),
  ])
  let mac = @mooncry.hmac_sha256(self.secret, body)
  let token = retry_token_join([body, mac])
  if token.length() > retry_token_max_length {
    return Err(LimitExceeded("Retry token", retry_token_max_length))
  }
  Ok(token)
}

///|
/// Authenticates a returned Initial token before making an opaque context.
/// The driver constructor additionally checks its endpoint and wire CIDs.
pub fn QuicRetryTokenManager::validate_initial(
  self : QuicRetryTokenManager,
  endpoint : @types.Endpoint,
  token : Bytes,
  now_ms : Int64,
) -> Result[QuicRetryContext, QuicError] {
  if now_ms < 0L ||
    token.length() < 4 + 8 + 2 + 3 + 16 + 32 ||
    token.length() > retry_token_max_length {
    return Err(InvalidPacket("Retry token is malformed"))
  }
  let mac_offset = token.length() - 32
  let body = token[:mac_offset].to_owned()
  let supplied_mac = token[mac_offset:].to_owned()
  let expected_mac = @mooncry.hmac_sha256(self.secret, body)
  if !retry_token_equal(expected_mac, supplied_mac) {
    return Err(InvalidPacket("Retry token authentication failed"))
  }
  if body[:4] != retry_token_magic {
    return Err(InvalidPacket("Retry token version is unsupported"))
  }
  let mut issued = 0L
  for index in 0..<8 {
    issued = (issued << 8) | body[4 + index].to_int().to_int64()
  }
  if issued < 0L || issued > now_ms || now_ms - issued > self.lifetime_ms {
    return Err(InvalidPacket("Retry token has expired"))
  }
  let authority_length = (body[12].to_int() << 8) | body[13].to_int()
  let authority_start = 14
  let authority_end = authority_start + authority_length
  if authority_length > retry_token_max_endpoint_length ||
    authority_end + 3 + 16 > mac_offset {
    return Err(InvalidPacket("Retry token fields are truncated"))
  }
  let authority = body[authority_start:authority_end].to_owned()
  let expected_authority = @utf8.encode(
    endpoint.scheme() + "://" + endpoint.authority(),
  )
  if authority != expected_authority {
    return Err(InvalidPacket("Retry token endpoint does not match"))
  }
  let (original_destination, after_original) = match
    retry_token_read_cid(body, authority_end) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (retry_source, after_retry) = match
    retry_token_read_cid(body, after_original) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (client_source, after_client) = match
    retry_token_read_cid(body, after_retry) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if after_client + 16 != body.length() ||
    retry_source.bytes().is_empty() ||
    retry_source == original_destination {
    return Err(
      InvalidPacket("Retry token connection IDs or payload are invalid"),
    )
  }
  Ok({
    endpoint,
    original_destination,
    retry_source,
    client_source,
    issued_at_ms: issued,
    lifetime_ms: self.lifetime_ms,
    token,
  })
}

///|
fn QuicRetryContext::matches(
  self : QuicRetryContext,
  endpoint : @types.Endpoint,
  original_destination : ConnectionId,
  retry_source : ConnectionId,
  client_source : ConnectionId,
) -> Bool {
  self.endpoint == endpoint &&
  self.original_destination == original_destination &&
  self.retry_source == retry_source &&
  self.client_source == client_source
}

///|
fn QuicRetryContext::valid_at(self : QuicRetryContext, now_ms : Int64) -> Bool {
  now_ms >= self.issued_at_ms && now_ms - self.issued_at_ms <= self.lifetime_ms
}
