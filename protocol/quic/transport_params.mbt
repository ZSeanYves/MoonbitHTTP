///|
/// RFC 9000 transport parameters authenticated by TLS. Numeric limits are
/// separate from connection identity: neither is applied before authentication.
pub(all) struct QuicTransportParameters {
  limits : QuicTransportParams
  initial_source_connection_id : ConnectionId
  original_destination_connection_id : ConnectionId?
  retry_source_connection_id : ConnectionId?
  stateless_reset_token : Bytes?
  ack_delay_exponent : Int
  max_ack_delay : Int
  preferred_address : Bytes?
  max_datagram_frame_size : Int64
} derive(Eq, Debug)

///|
pub fn QuicTransportParameters::new(
  initial_source_connection_id : ConnectionId,
  original_destination_connection_id? : ConnectionId? = None,
  limits? : QuicTransportParams = QuicTransportParams::defaults(),
) -> QuicTransportParameters {
  {
    limits,
    initial_source_connection_id,
    original_destination_connection_id,
    retry_source_connection_id: None,
    stateless_reset_token: None,
    ack_delay_exponent: 3,
    max_ack_delay: 25,
    preferred_address: None,
    max_datagram_frame_size: 0L,
  }
}

///|
fn quic_validate_preferred_address(value : Bytes) -> Bool {
  if value.length() < 42 {
    return false
  }
  let cid_length = value[24].to_int()
  cid_length >= 1 &&
  cid_length <= QUIC_MAX_CONNECTION_ID &&
  value.length() == 41 + cid_length
}

///|
pub fn QuicTransportParameters::validate(
  self : QuicTransportParameters,
  sender_role : QuicRole,
) -> Result[Unit, QuicError] {
  match self.limits.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if sender_role == Client &&
    (
      self.original_destination_connection_id is Some(_) ||
      self.retry_source_connection_id is Some(_) ||
      self.stateless_reset_token is Some(_) ||
      self.preferred_address is Some(_)
    ) {
    return Err(
      InvalidTransportParameter("server-only parameter sent by client"),
    )
  }
  if sender_role == Server && self.original_destination_connection_id is None {
    return Err(
      InvalidTransportParameter("missing original_destination_connection_id"),
    )
  }
  if self.stateless_reset_token is Some(value) && value.length() != 16 {
    return Err(InvalidTransportParameter("stateless_reset_token"))
  }
  if self.preferred_address is Some(value) &&
    (
      !quic_validate_preferred_address(value) ||
      self.initial_source_connection_id.bytes().is_empty()
    ) {
    return Err(InvalidTransportParameter("preferred_address"))
  }
  if self.ack_delay_exponent < 0 || self.ack_delay_exponent > 20 {
    return Err(InvalidTransportParameter("ack_delay_exponent"))
  }
  if self.max_ack_delay < 0 || self.max_ack_delay >= 16384 {
    return Err(InvalidTransportParameter("max_ack_delay"))
  }
  if self.max_datagram_frame_size < 0L ||
    self.max_datagram_frame_size > QUIC_MAX_VARINT {
    return Err(InvalidTransportParameter("max_datagram_frame_size"))
  }
  Ok(())
}

///|
/// Bind TLS-authenticated identities to the packet header history. Absence of
/// Retry is authenticated too: an unsolicited retry_source_connection_id fails.
pub fn QuicTransportParameters::validate_connection_ids(
  self : QuicTransportParameters,
  expected_initial : ConnectionId,
  expected_original? : ConnectionId? = None,
  expected_retry? : ConnectionId? = None,
) -> Result[Unit, QuicError] {
  if self.initial_source_connection_id != expected_initial ||
    self.original_destination_connection_id != expected_original ||
    self.retry_source_connection_id != expected_retry {
    return Err(
      InvalidTransportParameter("connection ID does not match handshake"),
    )
  }
  Ok(())
}

///|
fn quic_parameter_bytes(out : Array[Byte], id : Int64, value : Bytes) -> Unit {
  for byte in QuicVarInt::new(id).unwrap().encode() {
    out.push(byte)
  }
  for byte in QuicVarInt::new(value.length().to_int64()).unwrap().encode() {
    out.push(byte)
  }
  for byte in value {
    out.push(byte)
  }
}

///|
pub fn QuicTransportParameters::encode(
  self : QuicTransportParameters,
  sender_role : QuicRole,
) -> Result[Bytes, QuicError] {
  match self.validate(sender_role) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let out : Array[Byte] = []
  if self.original_destination_connection_id is Some(cid) {
    quic_parameter_bytes(out, 0L, cid.bytes())
  }
  if self.stateless_reset_token is Some(token) {
    quic_parameter_bytes(out, 2L, token)
  }
  let numeric : Array[(Int64, Int64)] = [
    (1L, self.limits.max_idle_timeout),
    (3L, self.limits.max_udp_payload_size.to_int64()),
    (4L, self.limits.initial_max_data),
    (5L, self.limits.initial_max_stream_data_bidi_local),
    (6L, self.limits.initial_max_stream_data_bidi_remote),
    (7L, self.limits.initial_max_stream_data_uni),
    (8L, self.limits.initial_max_streams_bidi),
    (9L, self.limits.initial_max_streams_uni),
    (10L, self.ack_delay_exponent.to_int64()),
    (11L, self.max_ack_delay.to_int64()),
    (14L, self.limits.active_connection_id_limit),
  ]
  for (id, value) in numeric {
    quic_parameter_bytes(out, id, QuicVarInt::new(value).unwrap().encode())
  }
  if self.limits.disable_active_migration {
    quic_parameter_bytes(out, 12L, b"")
  }
  if self.preferred_address is Some(value) {
    quic_parameter_bytes(out, 13L, value)
  }
  quic_parameter_bytes(out, 15L, self.initial_source_connection_id.bytes())
  if self.retry_source_connection_id is Some(cid) {
    quic_parameter_bytes(out, 16L, cid.bytes())
  }
  if self.max_datagram_frame_size > 0L {
    quic_parameter_bytes(
      out,
      32L,
      QuicVarInt::new(self.max_datagram_frame_size).unwrap().encode(),
    )
  }
  Ok(Bytes::from_array(out))
}

///|
fn quic_parameter_integer(bytes : BytesView) -> Result[Int64, QuicError] {
  match quic_decode_varint(bytes) {
    Ok((value, consumed)) if consumed == bytes.length() => Ok(value.value())
    _ => Err(InvalidTransportParameter("invalid integer parameter length"))
  }
}

///|
pub fn QuicTransportParameters::decode(
  input : BytesView,
  peer_role : QuicRole,
  max_bytes? : Int = 65535,
  max_parameters? : Int = 64,
) -> Result[QuicTransportParameters, QuicError] {
  if max_bytes < 0 || input.length() > max_bytes || max_parameters < 1 {
    return Err(LimitExceeded("transport parameters", max_bytes))
  }
  // RFC defaults differ from our chosen local policy defaults. In particular,
  // omitted flow limits grant no credit; they must never inherit local values.
  let mut params : QuicTransportParams = {
    max_idle_timeout: 0L,
    max_udp_payload_size: 65527,
    initial_max_data: 0L,
    initial_max_stream_data_bidi_local: 0L,
    initial_max_stream_data_bidi_remote: 0L,
    initial_max_stream_data_uni: 0L,
    initial_max_streams_bidi: 0L,
    initial_max_streams_uni: 0L,
    active_connection_id_limit: 2L,
    disable_active_migration: false,
  }
  let mut original : ConnectionId? = None
  let mut initial : ConnectionId? = None
  let mut retry : ConnectionId? = None
  let mut token : Bytes? = None
  let mut preferred : Bytes? = None
  let mut exponent = 3
  let mut delay = 25
  let mut datagram = 0L
  let seen : Map[Int64, Bool] = Map([])
  let mut cursor = 0
  while cursor < input.length() {
    let (id, consumed) = match quic_decode_varint(input[cursor:]) {
      Ok(value) => value
      Err(_) => return Err(InvalidTransportParameter("truncated parameter ID"))
    }
    cursor += consumed
    let (length, consumed) = match quic_decode_varint(input[cursor:]) {
      Ok(value) => value
      Err(_) =>
        return Err(InvalidTransportParameter("truncated parameter length"))
    }
    cursor += consumed
    if length.value() > (input.length() - cursor).to_int64() {
      return Err(InvalidTransportParameter("truncated parameter value"))
    }
    if seen.get(id.value()) is Some(_) {
      return Err(InvalidTransportParameter("duplicate parameter"))
    }
    if seen.length() >= max_parameters {
      return Err(LimitExceeded("transport parameter count", max_parameters))
    }
    seen.set(id.value(), true)
    let value = input[cursor:cursor + length.value().to_int()]
    cursor += length.value().to_int()
    match id.value() {
      0L | 15L | 16L => {
        let cid = match ConnectionId::new(value.to_owned()) {
          Ok(cid) => cid
          Err(_) =>
            return Err(InvalidTransportParameter("connection ID length"))
        }
        match id.value() {
          0L => original = Some(cid)
          15L => initial = Some(cid)
          _ => retry = Some(cid)
        }
      }
      2L => token = Some(value.to_owned())
      12L => {
        if !value.is_empty() {
          return Err(
            InvalidTransportParameter("disable_active_migration length"),
          )
        }
        params = { ..params, disable_active_migration: true, }
      }
      13L => preferred = Some(value.to_owned())
      1L | 3L | 4L | 5L | 6L | 7L | 8L | 9L | 10L | 11L | 14L | 32L => {
        let number = match quic_parameter_integer(value) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        match id.value() {
          1L => params = { ..params, max_idle_timeout: number, }
          3L => {
            if number > 65527L {
              return Err(InvalidTransportParameter("max_udp_payload_size"))
            }
            params = { ..params, max_udp_payload_size: number.to_int(), }
          }
          4L => params = { ..params, initial_max_data: number, }
          5L =>
            params = { ..params, initial_max_stream_data_bidi_local: number, }
          6L =>
            params = { ..params, initial_max_stream_data_bidi_remote: number, }
          7L => params = { ..params, initial_max_stream_data_uni: number, }
          8L => params = { ..params, initial_max_streams_bidi: number, }
          9L => params = { ..params, initial_max_streams_uni: number, }
          10L => {
            if number > 20L {
              return Err(InvalidTransportParameter("ack_delay_exponent"))
            }
            exponent = number.to_int()
          }
          11L => {
            if number >= 16384L {
              return Err(InvalidTransportParameter("max_ack_delay"))
            }
            delay = number.to_int()
          }
          14L => params = { ..params, active_connection_id_limit: number, }
          _ => datagram = number
        }
      }
      _ => () // Unknown extensions are ignored after length/duplicate checks.
    }
  }
  guard initial is Some(initial) else {
    return Err(
      InvalidTransportParameter("missing initial_source_connection_id"),
    )
  }
  let result : QuicTransportParameters = {
    limits: params,
    initial_source_connection_id: initial,
    original_destination_connection_id: original,
    retry_source_connection_id: retry,
    stateless_reset_token: token,
    preferred_address: preferred,
    ack_delay_exponent: exponent,
    max_ack_delay: delay,
    max_datagram_frame_size: datagram,
  }
  match result.validate(peer_role) {
    Ok(_) => Ok(result)
    Err(error) => Err(error)
  }
}
