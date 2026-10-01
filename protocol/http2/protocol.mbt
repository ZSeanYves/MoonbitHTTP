///|
pub(all) enum H2ErrorCode {
  NoError
  ProtocolError
  InternalError
  FlowControlError
  SettingsTimeout
  StreamClosed
  FrameSizeError
  RefusedStream
  Cancel
  CompressionError
  ConnectError
  EnhanceYourCalm
  InadequateSecurity
  Http11Required
} derive(Debug, Eq)

///|
pub(all) suberror H2ProtocolError {
  ConnectionError(H2ErrorCode, String)
  StreamError(Int, H2ErrorCode, String)
} derive(Debug, Eq)

///|
pub(all) enum H2Role {
  Client
  Server
} derive(Debug, Eq)

///|
pub(all) enum H2Action {
  PeerHeaderTableSize(Int)
  SendSettingsAck
  SendPingAck(Array[Byte])
  HeadersStarted(Int, Bool)
  HeadersContinued(Int, Bool)
  DataReceived(Int, Array[Byte], Bool, Int)
  StreamResetReceived(Int, Int)
  GoawayReceived(Int, Int)
  WindowAvailable(Int, Int)
  SendWindowUpdate(Int, Int)
}
