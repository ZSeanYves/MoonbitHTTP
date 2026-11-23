///|
using @types {type Endpoint, type EndpointError, type IpAddress}

///|
#derive(Eq, Debug)
pub(all) enum TransportOperation {
  Resolve
  Connect
  Accept
  Send
  Receive
  Close
  ProxyConnect
  QuicEndpoint
}

///|
#derive(Debug, Eq)
pub(all) suberror ConnectOptionsError {
  InvalidTimeout
  InvalidLocalPort
  InvalidLocalHost
}

///|
#derive(Debug, Eq)
pub(all) suberror TransportError {
  InvalidEndpoint(EndpointError)
  InvalidOptions(ConnectOptionsError)
  Failed(TransportOperation, String)
  Closed
  Timeout(TransportOperation)
  Cancelled
  Unsupported(TransportOperation)
  InvalidDatagramSize
  InvalidResolveOptions
  Policy(PolicyError)
  /// The host system error number and original diagnostic are preserved.
  SystemFailure(TransportOperation, Int32, String)
  NativeFailure(TransportOperation, UInt64, Int64, String)
}

///|
#derive(Eq, Debug)
pub(all) suberror EntropyError {
  Unavailable
  Failed(String)
  InvalidBuffer
}
