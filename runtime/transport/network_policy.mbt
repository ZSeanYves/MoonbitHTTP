///|
pub(all) enum PolicyOperation {
  Listen
  Accept
  Resolve
  Connect
  Redirect
  ProxyConnect
  QuicEndpoint
} derive(Eq, Debug)

///|
pub(all) suberror PolicyError {
  Denied(PolicyOperation, String)
  InvalidRule(String)
} derive(Eq, Debug)

///|
pub(open) trait NetworkPolicy {
  fn authorize(Self, Endpoint, PolicyOperation) -> Result[Unit, PolicyError]
}

///|
pub struct AllowAllPolicy(Unit)

///|
pub fn AllowAllPolicy::new() -> AllowAllPolicy {
  AllowAllPolicy(())
}

///|
pub impl NetworkPolicy for AllowAllPolicy with fn authorize(
  _self,
  _endpoint,
  _operation,
) {
  Ok(())
}

///|
pub struct DenyAllPolicy(Unit)

///|
pub fn DenyAllPolicy::new() -> DenyAllPolicy {
  DenyAllPolicy(())
}

///|
pub impl NetworkPolicy for DenyAllPolicy with fn authorize(
  _self,
  _endpoint,
  operation,
) {
  Err(Denied(operation, "network policy denied operation"))
}
