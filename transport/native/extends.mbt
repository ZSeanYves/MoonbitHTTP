///|
pub extend TcpConnector with @transport.StreamConnector::{connect}

///|
pub extend UdpSocket with @transport.DatagramSocket::{send, receive, close}

///|
pub extend NativeResolver with @transport.NameResolver::{resolve}

///|
pub extend NativeClock with @transport.Clock::{
  monotonic_millis,
  wall_clock_seconds,
}
