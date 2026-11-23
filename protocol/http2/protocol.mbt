///|
#derive(Debug, Eq)
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
}

///|
#derive(Debug, Eq)
pub(all) suberror H2ProtocolError {
  ConnectionError(H2ErrorCode, String)
  StreamError(Int32, H2ErrorCode, String)
}

///|
#derive(Debug, Eq)
pub(all) enum H2Role {
  Client
  Server
}

///|
pub(all) enum H2Action {
  PeerHeaderTableSize(Int32)
  SendSettingsAck
  SendPingAck(Array[Byte])
  HeadersStarted(Int32, Bool)
  // Decode this field block to retain connection-wide HPACK state, then reset
  // the stream with the supplied error. Do not dispatch its decoded fields.
  // Further fragments use HeadersContinued until END_HEADERS.
  HeadersDiscarded(Int32, Bool, H2ErrorCode)
  HeadersContinued(Int32, Bool)
  DataReceived(Int32, Array[Byte], Bool, Int32)
  StreamResetReceived(Int32, Int32)
  GoawayReceived(Int32, Int32)
  WindowAvailable(Int32, Int32)
  SendWindowUpdate(Int32, Int32)
}
