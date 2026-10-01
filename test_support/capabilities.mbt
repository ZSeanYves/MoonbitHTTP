///|
pub(all) struct FixedClock {
  mut monotonic : Int64
  mut wall_seconds : Int64
} derive(Debug, Eq)

///|
pub fn FixedClock::new(monotonic : Int64, wall_seconds : Int64) -> FixedClock {
  { monotonic, wall_seconds, }
}

///|
pub impl @transport.Clock for FixedClock with fn monotonic_millis(self) {
  self.monotonic
}

///|
pub impl @transport.Clock for FixedClock with fn wall_clock_seconds(self) {
  self.wall_seconds
}

///|
pub fn FixedClock::advance(
  self : FixedClock,
  millis : Int64,
) -> Result[Unit, String] {
  guard millis >= 0 else { return Err("clock cannot move backwards") }
  self.monotonic += millis
  self.wall_seconds += millis / 1000
  Ok(())
}

///|
pub struct ZeroEntropy(Unit)

///|
pub fn ZeroEntropy::new() -> ZeroEntropy {
  ZeroEntropy(())
}

///|
pub impl @transport.Entropy for ZeroEntropy with fn fill(_self, buffer) {
  for i in 0..<buffer.length() {
    buffer[i] = 0
  }
  Ok(())
}

///|
/// Deterministic datagram substitute used only by protocol tests.
/// It has an explicit size limit and never silently truncates a datagram.
pub struct MemoryDatagramSocket {
  inbound : @aqueue.Queue[@transport.Datagram]
  sent : Array[@transport.Datagram]
  max_datagram_size : Int
  mut closed : Bool
}

///|
pub fn MemoryDatagramSocket::new(
  max_datagram_size? : Int = 65527,
) -> Result[MemoryDatagramSocket, @transport.TransportError] {
  if max_datagram_size <= 0 {
    return Err(InvalidDatagramSize)
  }
  Ok({
    inbound: Queue(kind=Blocking(64)),
    sent: [],
    max_datagram_size,
    closed: false,
  })
}

///|
pub fn MemoryDatagramSocket::inject(
  self : MemoryDatagramSocket,
  datagram : @transport.Datagram,
) -> Result[Unit, @transport.TransportError] {
  if self.closed {
    return Err(Closed)
  }
  if datagram.payload.length() > self.max_datagram_size {
    return Err(InvalidDatagramSize)
  }
  let accepted = self.inbound.try_put(datagram) catch { _ => false }
  if !accepted {
    return Err(Failed(Receive, "memory datagram queue is full"))
  }
  Ok(())
}

///|
pub fn MemoryDatagramSocket::sent(
  self : MemoryDatagramSocket,
) -> Array[@transport.Datagram] {
  self.sent.copy()
}

///|
pub impl @transport.DatagramSocket for MemoryDatagramSocket with fn send(
  self,
  endpoint,
  payload,
) {
  if self.closed {
    return Err(Closed)
  }
  if payload.length() > self.max_datagram_size {
    return Err(InvalidDatagramSize)
  }
  self.sent.push({ payload, endpoint, })
  Ok(())
}

///|
pub impl @transport.DatagramSocket for MemoryDatagramSocket with fn receive(
  self,
  max_bytes,
) {
  if self.closed {
    return Err(Closed)
  }
  if max_bytes <= 0 || max_bytes > self.max_datagram_size {
    return Err(InvalidDatagramSize)
  }
  let datagram = self.inbound.get() catch { _ => return Err(Closed) }
  if datagram.payload.length() > max_bytes {
    return Err(InvalidDatagramSize)
  }
  Ok(datagram)
}

///|
pub impl @transport.DatagramSocket for MemoryDatagramSocket with fn close(self) {
  if !self.closed {
    self.closed = true
    self.inbound.close(error=@transport.TransportError::Closed, clear=true)
  }
}
