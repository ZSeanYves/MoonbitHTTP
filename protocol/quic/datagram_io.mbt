///|
/// One capability-bound receive step.  It is intentionally separate from the
/// core so tests can drive `on_datagram` with deterministic byte arrays.
pub async fn[S : @transport.DatagramSocket] QuicDatagramDriver::receive_once(
  self : QuicDatagramDriver,
  socket : S,
  max_bytes : Int32,
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
  match action {
    SendDatagram(_, _) if self.state() == Draining || self.state() == Closed =>
      Err(self.connection.closed_error())
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
