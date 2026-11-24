///|
/// Keep the original type and error identities for users of either import path.
pub using @uv {
  type CallbackTransport,
  type CallbackCountError,
  type CallbackTransportClosed,
}
