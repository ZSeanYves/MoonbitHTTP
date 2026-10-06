///|
/// Owns TLS handshake framing and its provider. The packet driver remains the
/// sole owner of CRYPTO reassembly, retransmission and packet-number spaces.
pub struct QuicTlsDriver[P] {
  priv driver : QuicDatagramDriver
  priv provider : P
  priv input : QuicHandshakeInput
  priv offsets : Array[Int64]
  priv pending : Array[QuicPendingCrypto]
  priv mut pending_bytes : Int
  priv mut started : Bool
  priv mut failure : QuicError?
}

///|
priv struct QuicPendingCrypto {
  space : PacketNumberSpace
  offset : Int64
  bytes : Bytes
}

///|
pub fn[P] QuicTlsDriver::new(
  driver : QuicDatagramDriver,
  provider : P,
) -> Result[QuicTlsDriver[P], QuicError] {
  if driver.state() != Handshaking {
    return Err(
      Unsupported("TLS driver requires a fresh handshaking connection"),
    )
  }
  let input = match
    QuicHandshakeInput::new(max_bytes_per_level=driver.limits.max_crypto_bytes) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    driver,
    provider,
    input,
    offsets: [0L, 0L, 0L],
    pending: [],
    pending_bytes: 0,
    started: false,
    failure: None,
  })
}

///|
pub fn[P] QuicTlsDriver::datagram_driver(
  self : QuicTlsDriver[P],
) -> QuicDatagramDriver {
  self.driver
}

///|
/// Advances packet recovery and retries TLS output held by congestion or
/// amplification limits. Event loops must drive this timer even when no peer
/// datagram arrives; otherwise a lost handshake flight can stall indefinitely.
pub fn[P] QuicTlsDriver::poll(
  self : QuicTlsDriver[P],
  now_ms : Int64,
) -> Result[Array[QuicDriverAction], QuicError] {
  if self.failure is Some(error) {
    return Err(error)
  }
  if !self.started {
    return Err(Unsupported("QUIC TLS handshake has not started"))
  }
  let actions = match self.driver.poll(now_ms) {
    Ok(value) => value
    Err(error) => return Err(self.fail(error))
  }
  if self.driver.state() == Closed || self.driver.state() == Draining {
    self.pending.clear()
    self.pending_bytes = 0
    return Ok(actions)
  }
  match self.flush_crypto(now_ms) {
    Ok(pending) => {
      actions.append(pending)
      Ok(actions)
    }
    Err(error) => Err(self.fail(error))
  }
}

///|
fn[P] QuicTlsDriver::fail(
  self : QuicTlsDriver[P],
  error : QuicError,
) -> QuicError {
  self.failure = Some(error)
  self.driver.connection.state = Closed
  error
}

///|
pub fn[P : @transport.QuicTlsProvider] QuicTlsDriver::start(
  self : QuicTlsDriver[P],
  options : @transport.TlsOptions,
  now_ms : Int64,
) -> Result[Array[QuicDriverAction], QuicError] {
  if self.failure is Some(error) {
    return Err(error)
  }
  if self.started {
    return Err(Unsupported("QUIC TLS handshake already started"))
  }
  self.started = true
  let driver = self.driver
  let base_params = QuicTransportParameters::new(
    driver.local_connection_id,
    limits=driver.transport_params,
    original_destination_connection_id=if driver.role == Server {
      Some(driver.original_destination)
    } else {
      None
    },
  )
  let params = {
    ..base_params,
    retry_source_connection_id: driver.retry_source,
  }
  let encoded = match params.encode(driver.role) {
    Ok(value) => value
    Err(error) => return Err(self.fail(error))
  }
  let events = match self.provider.start(options, encoded) {
    Ok(value) => value
    Err(error) => return Err(self.fail(Tls(error)))
  }
  match self.run_tls_events(events, now_ms) {
    Ok(value) => Ok(value)
    Err(error) => Err(self.fail(error))
  }
}

///|
pub fn[P : @transport.QuicTlsProvider] QuicTlsDriver::on_datagram(
  self : QuicTlsDriver[P],
  source : @types.Endpoint,
  packet : Bytes,
  now_ms : Int64,
) -> Result[Array[QuicDriverAction], QuicError] {
  if packet.is_empty() ||
    packet.length() > self.driver.transport_params.max_udp_payload_size {
    return Err(
      LimitExceeded(
        "QUIC datagram",
        self.driver.transport_params.max_udp_payload_size,
      ),
    )
  }
  self.driver.count_received_datagram(source, packet)
  let actions : Array[QuicDriverAction] = []
  let mut cursor = 0
  while cursor < packet.length() {
    let remaining = packet[cursor:].to_owned()
    // Retry and Version Negotiation consume a whole datagram and have neither
    // a packet number nor a protected payload length. The shared packet
    // driver owns their state transitions, including ClientHello replay.
    if remaining.length() >= 5 &&
      (remaining[0].to_int() & 0x80) != 0 &&
      (
        packet_version(remaining) != QUIC_VERSION_1 ||
        ((remaining[0].to_int() >> 4) & 3) == 3
      ) {
      if cursor > 0 {
        break
      }
      let special = match
        self.driver.receive_negotiation_packet(source, remaining, now_ms) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      actions.append(special)
      cursor = packet.length()
      continue
    }
    // Each coalesced packet is independent. Invalid trailing bytes must not
    // erase actions from an earlier authenticated packet in this datagram.
    if (remaining[0].to_int() & 0x40) == 0 {
      if cursor > 0 {
        break
      }
      return Err(InvalidPacket("QUIC fixed bit is not set"))
    }
    let length = if (remaining[0].to_int() & 0x80) == 0 {
      remaining.length()
    } else {
      let (_, _, _, _, offset, payload_length) = match
        quic_long_header_fields(remaining) {
        Ok(value) => value
        Err(_) if cursor > 0 => break
        Err(error) => return Err(error)
      }
      if payload_length > (remaining.length() - offset).to_int64() {
        if cursor > 0 {
          break
        }
        return Err(NeedMoreInput)
      }
      offset + payload_length.to_int()
    }
    let next = match
      self.on_packet(source, remaining[:length].to_owned(), now_ms) {
      Ok(value) => value
      Err(_) if cursor > 0 && self.failure is None => break
      Err(error) => return Err(error)
    }
    actions.append(next)
    cursor += length
  }
  let pending = match self.flush_crypto(now_ms) {
    Ok(value) => value
    Err(error) => return Err(self.fail(error))
  }
  actions.append(pending)
  Ok(actions)
}

///|
fn[P : @transport.QuicTlsProvider] QuicTlsDriver::on_packet(
  self : QuicTlsDriver[P],
  source : @types.Endpoint,
  packet : Bytes,
  now_ms : Int64,
) -> Result[Array[QuicDriverAction], QuicError] {
  if self.failure is Some(error) {
    return Err(error)
  }
  if !self.started {
    return Err(Unsupported("QUIC TLS handshake has not started"))
  }
  let incoming = match self.driver.on_packet(source, packet, now_ms) {
    Ok(value) => value
    // Authentication failures can be dropped without poisoning TLS state.
    Err(error) => return Err(error)
  }
  let actions : Array[QuicDriverAction] = []
  for action in incoming {
    match action {
      CryptoData(space, offset, bytes) => {
        let messages = match self.input.feed(space, offset, bytes) {
          Ok(value) => value
          Err(error) => return Err(self.fail(error))
        }
        for message in messages {
          let events = match self.provider.receive_handshake(message) {
            Ok(value) => value
            Err(error) => return Err(self.fail(Tls(error)))
          }
          let output = match self.run_tls_events(events, now_ms) {
            Ok(value) => value
            Err(error) => return Err(self.fail(error))
          }
          actions.append(output)
        }
      }
      _ => actions.push(action)
    }
  }
  Ok(actions)
}

///|
fn[P] QuicTlsDriver::run_tls_events(
  self : QuicTlsDriver[P],
  events : Array[@transport.QuicTlsEvent],
  now_ms : Int64,
) -> Result[Array[QuicDriverAction], QuicError] {
  let actions : Array[QuicDriverAction] = []
  let deferred : Array[Bytes] = []
  for event in events {
    match event {
      TrafficSecret(level, direction, suite, secret) =>
        match
          self.driver.install_traffic_secret(level, direction, secret, suite~) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
      HandshakeBytes(QuicApplication, bytes) => deferred.push(bytes)
      HandshakeBytes(level, bytes) => {
        let output = match self.send_crypto(level, bytes, now_ms) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        actions.append(output)
      }
      HandshakeComplete(alpn, encoded) => {
        if alpn != "h3" {
          return Err(Tls(Unsupported))
        }
        let peer_role = if self.driver.role == Client { Server } else { Client }
        let params = match QuicTransportParameters::decode(encoded, peer_role) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        match self.driver.set_peer_transport_parameters(params) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
        match self.driver.establish() {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
        if self.driver.role == Server {
          match self.driver.send_frames(Application, [HandshakeDone], now_ms) {
            Ok(action) => actions.push(action)
            Err(error) => return Err(error)
          }
          self.driver.discard_packet_space(Handshake)
        }
      }
    }
  }
  for bytes in deferred {
    let output = match self.send_crypto(QuicApplication, bytes, now_ms) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    actions.append(output)
  }
  Ok(actions)
}

///|
fn[P] QuicTlsDriver::send_crypto(
  self : QuicTlsDriver[P],
  level : @transport.QuicEncryptionLevel,
  bytes : Bytes,
  now_ms : Int64,
) -> Result[Array[QuicDriverAction], QuicError] {
  let (space, index) : (PacketNumberSpace, Int) = match level {
    QuicInitial => (Initial, 0)
    QuicHandshake => (Handshake, 1)
    QuicApplication => (Application, 2)
  }
  // Client Initial CRYPTO is retained verbatim for Retry retransmission.
  // Reserve the supported token budget before the first flight so adding a
  // Retry token cannot make an already retained frame exceed the path MTU.
  let retry_budget = if space == Initial && self.driver.role == Client {
    retry_token_max_length
  } else {
    0
  }
  let max_chunk = self.driver.send_datagram_limit().min(1200) -
    128 -
    retry_budget
  let limit = self.driver.limits.max_crypto_bytes
  if bytes.length() > limit - self.pending_bytes ||
    bytes.length().to_int64() > limit.to_int64() - self.offsets[index] {
    return Err(LimitExceeded("pending TLS CRYPTO", limit))
  }
  let mut cursor = 0
  while cursor < bytes.length() {
    let end = (cursor + max_chunk).min(bytes.length())
    self.pending.push({
      space,
      offset: self.offsets[index],
      bytes: bytes[cursor:end].to_owned(),
    })
    self.pending_bytes += end - cursor
    self.offsets[index] += (end - cursor).to_int64()
    cursor = end
  }
  self.flush_crypto(now_ms)
}

///|
/// Amplification and congestion limits postpone output without advancing a
/// packet number or discarding TLS bytes. New datagrams retry the same queue.
fn[P] QuicTlsDriver::flush_crypto(
  self : QuicTlsDriver[P],
  now_ms : Int64,
) -> Result[Array[QuicDriverAction], QuicError] {
  let actions : Array[QuicDriverAction] = []
  while !self.pending.is_empty() {
    let next = self.pending[0]
    let frame = Crypto(next.offset, next.bytes)
    match self.driver.send_frames(next.space, [frame], now_ms) {
      Ok(action) => {
        self.pending.remove(0) |> ignore
        self.pending_bytes -= next.bytes.length()
        actions.push(action)
      }
      Err(AmplificationBlocked) | Err(FlowControl(0L, _)) => break
      Err(error) => return Err(error)
    }
  }
  Ok(actions)
}

///|
/// Installs an authenticated transport-parameter extension. Low-level TLS
/// integrations must call this before establish; raw peer bytes are untrusted
/// until the TLS transcript and Finished have been verified.
pub fn QuicDatagramDriver::set_peer_transport_parameters(
  self : QuicDatagramDriver,
  params : QuicTransportParameters,
) -> Result[Unit, QuicError] {
  if self.peer_parameters is Some(_) {
    return Err(InvalidTransportParameter("peer parameters already installed"))
  }
  let peer_role = if self.role == Client { Server } else { Client }
  match params.validate(peer_role) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let expected = self.initial_peer_id.unwrap_or(self.peer_connection_id)
  match
    params.validate_connection_ids(
      expected,
      expected_original=if self.role == Client {
        Some(self.original_destination)
      } else {
        None
      },
      expected_retry=if self.role == Client { self.retry_source } else { None },
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match self.connection.set_peer_transport_params(params.limits) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  // Initial/Retry exchanges can replace the client's original destination.
  // Only TLS-authenticated peer identity seeds the application CID namespace.
  let ids = self.peer_connection_ids
  ids.ids = [
    {
      sequence: 0L,
      id: params.initial_source_connection_id,
      reset_token: params.stateless_reset_token.unwrap_or(b""),
      retired: false,
    },
  ]
  ids.retire_prior_to = 0L
  self.peer_connection_id = params.initial_source_connection_id
  self.peer_parameters = Some(params)
  self.recovery.peer_max_ack_delay_ms = params.max_ack_delay.to_int64()
  Ok(())
}

///|
fn QuicDatagramDriver::send_datagram_limit(self : QuicDatagramDriver) -> Int {
  match self.peer_parameters {
    Some(params) =>
      self.transport_params.max_udp_payload_size.min(
        params.limits.max_udp_payload_size,
      )
    None => self.transport_params.max_udp_payload_size.min(1200)
  }
}

///|
pub fn QuicDatagramDriver::open_unidirectional_stream(
  self : QuicDatagramDriver,
) -> Result[Int64, QuicError] {
  self.connection.open_unidirectional_stream()
}
