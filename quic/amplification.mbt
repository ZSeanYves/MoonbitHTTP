///|
priv struct QuicPathBudget {
  endpoint : @types.Endpoint
  mut received : Int64
  mut sent : Int64
  mut validated : Bool
}

///|
fn QuicPathBudget::new(
  endpoint : @types.Endpoint,
  validated : Bool,
) -> QuicPathBudget {
  { endpoint, received: 0L, sent: 0L, validated, }
}

///|
fn QuicDatagramDriver::path_budget(
  self : QuicDatagramDriver,
  endpoint : @types.Endpoint,
) -> QuicPathBudget? {
  if self.active_budget.endpoint == endpoint {
    return Some(self.active_budget)
  }
  match self.candidate_budget {
    Some(budget) if budget.endpoint == endpoint => Some(budget)
    _ => None
  }
}

///|
/// RFC 9000 section 8.1 counts the complete uniquely attributable datagram,
/// including packets that are discarded. Coalesced packets call this once.
fn QuicDatagramDriver::count_received_datagram(
  self : QuicDatagramDriver,
  source : @types.Endpoint,
  packet : Bytes,
) -> Unit {
  if packet.is_empty() ||
    packet.length() > self.transport_params.max_udp_payload_size {
    return
  }
  let budget = match self.path_budget(source) {
    Some(value) => value
    None => return
  }
  let attributable = if (packet[0].to_int() & 0x80) != 0 {
    match quic_long_header_connection_ids(packet) {
      Ok((_, destination, _)) =>
        destination == self.local_connection_id ||
        (self.role == Server && destination == self.initial_destination)
      Err(_) => false
    }
  } else {
    let end = 1 + self.local_connection_id.bytes().length()
    packet.length() >= end &&
    packet[1:end].to_owned() == self.local_connection_id.bytes()
  }
  if attributable {
    budget.received = (budget.received + packet.length().to_int64()).min(
      QUIC_MAX_VARINT / 3L,
    )
  }
}

///|
fn QuicDatagramDriver::check_amplification(
  self : QuicDatagramDriver,
  destination : @types.Endpoint,
  bytes : Int,
) -> Result[Unit, QuicError] {
  // RFC 9000 section 21.1.1.1 exempts clients initiating a connection or
  // migration. Servers cannot borrow credit from the previous path.
  if self.role == Client {
    return Ok(())
  }
  let budget = match self.path_budget(destination) {
    Some(value) => value
    None => return Err(AmplificationBlocked)
  }
  if !budget.validated && bytes.to_int64() > budget.received * 3L - budget.sent {
    return Err(AmplificationBlocked)
  }
  Ok(())
}

///|
fn QuicDatagramDriver::count_sent_datagram(
  self : QuicDatagramDriver,
  destination : @types.Endpoint,
  bytes : Int,
) -> Unit {
  if self.path_budget(destination) is Some(budget) {
    budget.sent = (budget.sent + bytes.to_int64()).min(QUIC_MAX_VARINT)
  }
}
