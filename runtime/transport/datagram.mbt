///|
pub(all) struct Datagram {
  payload : Bytes
  endpoint : Endpoint
} derive(Debug, Eq)

///|
pub fn Datagram::new(payload : Bytes, endpoint : Endpoint) -> Datagram {
  { payload, endpoint, }
}

///|
pub fn Datagram::payload(self : Datagram) -> Bytes {
  self.payload
}

///|
pub fn Datagram::endpoint(self : Datagram) -> Endpoint {
  self.endpoint
}

///|
pub(open) trait DatagramSocket {
  async fn send(Self, Endpoint, Bytes) -> Result[Unit, TransportError]
  async fn receive(Self, Int) -> Result[Datagram, TransportError]
  fn close(Self) -> Unit
}
