///|
fn QuicDatagramDriver::select_peer_cid(
  self : QuicDatagramDriver,
  id : ConnectionId,
  token : Bytes?,
) -> Unit {
  if self.peer_connection_id != id {
    self.reset_destinations.clear()
    self.peer_connection_id = id
  }
  self.peer_reset_token = token
}

///|
/// Packet emission is the driver's send commit point, including for packets
/// handed to an external UDP implementation. A blocked send never gets here.
fn QuicDatagramDriver::remember_reset_destination(
  self : QuicDatagramDriver,
  destination : @types.Endpoint,
) -> Unit {
  let recent = self.reset_destinations
  if recent.last() == Some(destination) {
    return
  }
  if recent.search(destination) is Some(index) {
    ignore(recent.remove(index))
  } else if recent.length() == 8 {
    // Preserve the active path when repeated probes visit other addresses.
    let oldest = if recent[0] == self.path.active() { 1 } else { 0 }
    ignore(recent.remove(oldest))
  }
  recent.push(destination)
}

///|
/// A shared UDP socket can deliver an otherwise unroutable reset here. A
/// match enters draining and returns the error to wake the connection owner.
/// Tokens are eligible only after emitting a packet with their CID to this
/// address. The driver changes its sending CID when retiring its previous ID.
pub fn QuicDatagramDriver::receive_stateless_reset(
  self : QuicDatagramDriver,
  source : @types.Endpoint,
  datagram : BytesView,
) -> QuicError? {
  guard self.peer_reset_token is Some(token) &&
    datagram.length() >= 21 &&
    self.state() != Closed &&
    self.state() != Draining &&
    self.reset_destinations.contains(source) &&
    quic_token_equal(token, datagram[datagram.length() - 16:]) else {
    return None
  }
  self.connection.state = Draining
  self.connection.peer_close = Some(StatelessReset)
  Some(ConnectionClosed(0L, stateless_reset_reason))
}

///|
let stateless_reset_reason = "QUIC stateless reset"
