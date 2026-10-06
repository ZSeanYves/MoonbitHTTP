///|
/// Events emitted by the QUIC datagram driver.  The driver owns packet
/// protection, packet-number spaces, recovery and connection bookkeeping, but
/// leaves UDP I/O to the `DatagramSocket` capability.
pub(all) enum QuicDriverAction {
  SendDatagram(@types.Endpoint, Bytes)
  StreamData(Int64, Bytes, Bool)
  StreamReset(Int64, Int64)
  CryptoData(PacketNumberSpace, Int64, Bytes)
  PathValidated(@types.Endpoint)
  ConnectionClosed(Int64, String)
  RetryReceived(ConnectionId)
  PacketIgnored
} derive(Eq, Debug)

///|
fn quic_driver_join(parts : Array[Bytes]) -> Bytes {
  let mut length = 0
  for part in parts {
    length += part.length()
  }
  let output = FixedArray::make(length, b'\x00')
  let mut cursor = 0
  for part in parts {
    for byte in part {
      output[cursor] = byte
      cursor += 1
    }
  }
  output.unsafe_reinterpret_as_bytes()
}

///|
pub struct QuicDatagramDriver {
  priv role : QuicRole
  priv limits : QuicLimits
  priv transport_params : QuicTransportParams
  priv connection : QuicConnection
  priv local_connection_id : ConnectionId
  /// Current Initial DCID. A client replaces this with the Retry SCID after a
  /// validated Retry packet; `original_destination` remains immutable for the
  /// authenticated transport parameter.
  priv mut initial_destination : ConnectionId
  priv original_destination : ConnectionId
  priv mut initial_token : Bytes
  priv mut retry_source : ConnectionId?
  priv mut initial_peer_id : ConnectionId?
  priv mut peer_parameters : QuicTransportParameters?
  // When present, Initial tokens are verified before the server marks the
  // client's address as validated or switches to Retry-derived keys.
  priv retry_tokens : QuicRetryTokenManager?
  priv retry_context : QuicRetryContext?
  // The client learns that the server validated its address from an ACK for
  // Handshake/Application data. Its own amplification exemption is unrelated.
  priv mut peer_address_validated : Bool
  priv mut peer_connection_id : ConnectionId
  priv mut initial_send_keys : @tls.QuicPacketKeys?
  priv mut initial_receive_keys : @tls.QuicPacketKeys?
  priv mut handshake_send_keys : @tls.QuicPacketKeys?
  priv mut handshake_receive_keys : @tls.QuicPacketKeys?
  priv mut application_send_keys : @tls.QuicPacketKeys?
  priv mut application_receive_keys : @tls.QuicPacketKeys?
  priv key_update : QuicKeyUpdateState
  priv mut recovery : QuicRecovery
  priv path : QuicPathManager
  priv mut active_budget : QuicPathBudget
  priv mut candidate_budget : QuicPathBudget?
  priv peer_connection_ids : QuicConnectionIdManager
  priv pending_retirements : Array[Int64]
  priv mut largest_initial_received : Int64
  priv mut largest_handshake_received : Int64
  priv mut largest_application_received : Int64
  priv mut next_initial_packet : Int64
  priv mut next_handshake_packet : Int64
  priv mut next_application_packet : Int64
  priv mut seen_initial : Array[Int64]
  priv seen_handshake : Array[Int64]
  priv seen_application : Array[Int64]
  priv crypto_initial : QuicCryptoReassembler
  priv crypto_handshake : QuicCryptoReassembler
  priv crypto_application : QuicCryptoReassembler
  priv retransmissions : Array[QuicRetransmission]
  priv max_retransmissions : Int
  priv authorize_endpoint : (@types.Endpoint, @transport.PolicyOperation) -> Result[
    Unit,
    @transport.PolicyError,
  ]
}

///|
pub fn QuicDatagramDriver::state(
  self : QuicDatagramDriver,
) -> QuicConnectionState {
  self.connection.state()
}

///|
pub fn QuicDatagramDriver::endpoint(
  self : QuicDatagramDriver,
) -> @types.Endpoint {
  self.path.active()
}

///|
/// Returns the current path validation state without exposing the manager.
pub fn QuicDatagramDriver::path_status(
  self : QuicDatagramDriver,
) -> QuicPathStatus {
  self.path.status()
}

///|
pub fn QuicDatagramDriver::connection(
  self : QuicDatagramDriver,
) -> QuicConnection {
  self.connection
}

///|
pub fn QuicDatagramDriver::local_connection_id(
  self : QuicDatagramDriver,
) -> ConnectionId {
  self.local_connection_id
}

///|
pub fn QuicDatagramDriver::peer_connection_id(
  self : QuicDatagramDriver,
) -> ConnectionId {
  self.peer_connection_id
}

///|
pub fn QuicDatagramDriver::install_handshake_keys(
  self : QuicDatagramDriver,
  send : @tls.QuicPacketKeys,
  receive : @tls.QuicPacketKeys,
) -> Result[Unit, QuicError] {
  if self.state() != Handshaking ||
    self.handshake_send_keys is Some(_) ||
    self.handshake_receive_keys is Some(_) {
    return Err(
      Unsupported("handshake keys can only be installed once during handshake"),
    )
  }
  if send.cipher_suite() != receive.cipher_suite() {
    return Err(InvalidPacket("TLS directional cipher suites differ"))
  }
  self.handshake_send_keys = Some(send)
  self.handshake_receive_keys = Some(receive)
  Ok(())
}

///|
pub fn QuicDatagramDriver::install_application_keys(
  self : QuicDatagramDriver,
  send : @tls.QuicPacketKeys,
  receive : @tls.QuicPacketKeys,
) -> Result[Unit, QuicError] {
  if self.state() != Handshaking ||
    self.application_send_keys is Some(_) ||
    self.application_receive_keys is Some(_) {
    return Err(
      Unsupported(
        "application keys can only be installed once during handshake",
      ),
    )
  }
  if send.cipher_suite() != receive.cipher_suite() {
    return Err(InvalidPacket("TLS directional cipher suites differ"))
  }
  match (self.handshake_send_keys, self.handshake_receive_keys) {
    (Some(send_handshake), Some(receive_handshake)) =>
      if send.cipher_suite() != send_handshake.cipher_suite() ||
        receive.cipher_suite() != receive_handshake.cipher_suite() {
        return Err(
          InvalidPacket("TLS cipher suite changed across encryption levels"),
        )
      }
    _ => return Err(Unsupported("application keys require handshake keys"))
  }
  self.application_send_keys = Some(send)
  self.application_receive_keys = Some(receive)
  self.key_update.next_receive = match receive.next_application_keys() {
    Ok(keys) => Some(keys)
    Err(error) => return Err(Tls(error))
  }
  Ok(())
}

///|
/// Low-level transport transition for callers that own TLS. The caller must
/// first verify the actual TLS handshake and authenticated transport parameters.
/// Installed packet keys alone do not authenticate a peer or prove completion.
pub fn QuicDatagramDriver::establish(
  self : QuicDatagramDriver,
) -> Result[Unit, QuicError] {
  if self.application_send_keys is None || self.application_receive_keys is None {
    return Err(
      Unsupported("cannot establish before application keys are installed"),
    )
  }
  match self.connection.establish() {
    Ok(_) => {
      self.discard_packet_space(Initial)
      self.key_update.confirmed = self.role == Server
      self.active_budget.validated = true
      Ok(())
    }
    Err(error) => Err(error)
  }
}

///|
fn QuicDatagramDriver::quic_driver_space_keys(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
  sending : Bool,
) -> Result[@tls.QuicPacketKeys, QuicError] {
  match (space, sending) {
    (Initial, true) =>
      match self.initial_send_keys {
        Some(keys) => Ok(keys)
        None => Err(Unsupported("Initial sending keys have been discarded"))
      }
    (Initial, false) =>
      match self.initial_receive_keys {
        Some(keys) => Ok(keys)
        None => Err(Unsupported("Initial receiving keys have been discarded"))
      }
    (Handshake, true) =>
      match self.handshake_send_keys {
        Some(keys) => Ok(keys)
        None => Err(Unsupported("Handshake keys are not installed"))
      }
    (Handshake, false) =>
      match self.handshake_receive_keys {
        Some(keys) => Ok(keys)
        None => Err(Unsupported("Handshake keys are not installed"))
      }
    (Application, true) =>
      match self.application_send_keys {
        Some(keys) => Ok(keys)
        None => Err(Unsupported("application keys are not installed"))
      }
    (Application, false) =>
      match self.application_receive_keys {
        Some(keys) => Ok(keys)
        None => Err(Unsupported("application keys are not installed"))
      }
  }
}

///|
/// One capability-bound receive step.  It is intentionally separate from the
/// core so tests can drive `on_datagram` with deterministic byte arrays.
pub async fn[S : @transport.DatagramSocket] QuicDatagramDriver::receive_once(
  self : QuicDatagramDriver,
  socket : S,
  max_bytes : Int,
  now_ms : Int64,
) -> Result[Array[QuicDriverAction], QuicError] {
  let datagram = match socket.receive(max_bytes) {
    Ok(value) => value
    Err(error) => return Err(Transport(error))
  }
  self.on_datagram(datagram.endpoint(), datagram.payload(), now_ms)
}

///|
pub async fn[S : @transport.DatagramSocket] QuicDatagramDriver::send_action(
  self : QuicDatagramDriver,
  socket : S,
  action : QuicDriverAction,
) -> Result[Unit, QuicError] {
  ignore(self)
  match action {
    SendDatagram(endpoint, bytes) =>
      match socket.send(endpoint, bytes) {
        Ok(_) => Ok(())
        Err(error) => {
          self.connection.state = Closed
          Err(Transport(error))
        }
      }
    _ => Ok(())
  }
}

///|
pub fn QuicDatagramDriver::new(
  role : QuicRole,
  endpoint : @types.Endpoint,
  initial_destination : ConnectionId,
  local_connection_id : ConnectionId,
  peer_connection_id : ConnectionId,
  retry_context? : QuicRetryContext? = None,
  limits? : QuicLimits = QuicLimits::defaults(),
  transport_params? : QuicTransportParams = QuicTransportParams::defaults(),
  recovery_config? : QuicRecoveryConfig = QuicRecoveryConfig::defaults(),
  now_ms? : Int64 = 0L,
  retry_tokens? : QuicRetryTokenManager? = None,
  authorize? : (@types.Endpoint, @transport.PolicyOperation) -> Result[
    Unit,
    @transport.PolicyError,
  ] = fn(_, _) { Ok(()) },
) -> Result[QuicDatagramDriver, QuicError] {
  if retry_context is Some(_) && role != Server {
    return Err(
      InvalidPacket(
        "Retry context is only supplied by a server after token validation",
      ),
    )
  }
  if retry_context is Some(context) {
    if !context.matches(
        endpoint,
        context.original_destination,
        initial_destination,
        peer_connection_id,
      ) ||
      local_connection_id != context.retry_source ||
      !context.valid_at(now_ms) {
      return Err(
        InvalidPacket("Retry context does not match endpoint, CIDs or time"),
      )
    }
  }
  match authorize(endpoint, QuicEndpoint) {
    Ok(_) => ()
    Err(error) => return Err(Policy(error))
  }
  match limits.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match transport_params.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let connection = match QuicConnection::new(role, limits~, transport_params~) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let recovery = match QuicRecovery::new(config=recovery_config, now_ms~) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let initial_keys = match quic_initial_packet_keys(initial_destination) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let send_keys = if role == Client { initial_keys.0 } else { initial_keys.1 }
  let receive_keys = if role == Client {
    initial_keys.1
  } else {
    initial_keys.0
  }
  let path = QuicPathManager::new(endpoint)
  let peer_connection_ids = match
    QuicConnectionIdManager::new(
      peer_connection_id,
      max_active=transport_params.active_connection_id_limit.to_int(),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let initial_crypto = match
    QuicCryptoReassembler::new(max_bytes=limits.max_crypto_bytes) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let handshake_crypto = match
    QuicCryptoReassembler::new(max_bytes=limits.max_crypto_bytes) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let application_crypto = match
    QuicCryptoReassembler::new(max_bytes=limits.max_crypto_bytes) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    role,
    limits,
    transport_params,
    connection,
    local_connection_id,
    initial_destination,
    original_destination: retry_context
    .map(fn(value) { value.original_destination })
    .unwrap_or(initial_destination),
    initial_token: b"",
    retry_source: retry_context.map(fn(value) { value.retry_source }),
    initial_peer_id: None,
    peer_parameters: None,
    retry_tokens,
    retry_context,
    peer_address_validated: retry_context is Some(_),
    peer_connection_id,
    initial_send_keys: Some(send_keys),
    initial_receive_keys: Some(receive_keys),
    handshake_send_keys: None,
    handshake_receive_keys: None,
    application_send_keys: None,
    application_receive_keys: None,
    key_update: QuicKeyUpdateState::new(),
    recovery,
    path,
    active_budget: QuicPathBudget::new(
      endpoint,
      role == Client || retry_context is Some(_),
    ),
    candidate_budget: None,
    peer_connection_ids,
    pending_retirements: [],
    largest_initial_received: -1L,
    largest_handshake_received: -1L,
    largest_application_received: -1L,
    next_initial_packet: 0L,
    next_handshake_packet: 0L,
    next_application_packet: 0L,
    seen_initial: [],
    seen_handshake: [],
    seen_application: [],
    crypto_initial: initial_crypto,
    crypto_handshake: handshake_crypto,
    crypto_application: application_crypto,
    retransmissions: [],
    max_retransmissions: recovery_config.max_tracked_packets,
    authorize_endpoint: authorize,
  })
}
