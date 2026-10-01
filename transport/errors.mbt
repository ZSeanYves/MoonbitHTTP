///|
using @types {type Endpoint, type EndpointError, type IpAddress}

///|
pub(all) enum TransportOperation {
  Resolve
  Connect
  Accept
  Send
  Receive
  Close
  ProxyConnect
  QuicEndpoint
} derive(Eq, Debug)

///|
pub(all) suberror ConnectOptionsError {
  InvalidTimeout
  InvalidLocalPort
  InvalidLocalHost
} derive(Debug, Eq)

///|
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
  SystemFailure(TransportOperation, Int, String)
  NativeFailure(TransportOperation, UInt64, Int64, String)
} derive(Debug, Eq)

///|
pub(all) suberror EntropyError {
  Unavailable
  Failed(String)
  InvalidBuffer
} derive(Eq, Debug)
