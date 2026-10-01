///|
pub extend TcpConnector with @transport_api.StreamConnector::{connect}

///|
pub extend UdpSocket with @transport_api.DatagramSocket::{send, receive, close}

///|
pub extend UdpServerSocket with @transport_api.DatagramSocket::{
  send,
  receive,
  close,
}

///|
pub extend NativeResolver with @transport_api.NameResolver::{resolve}

///|
pub extend NativeClock with @transport_api.Clock::{
  monotonic_millis,
  wall_clock_seconds,
}
