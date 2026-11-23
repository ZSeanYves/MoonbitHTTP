///|
/// Authority always comes from the routed URI. Only forward proxies may receive proxy credentials.
fn client_wire_headers(
  source : @types.HeaderMap,
  include_proxy_authorization~ : Bool,
) -> @types.HeaderMap {
  let output = @types.HeaderMap::new()
  for field in source.fields() {
    if field.name.value == "host" ||
      (
        !include_proxy_authorization &&
        field.name.value == "proxy-authorization"
      ) {
      continue
    }
    output.append(field.name, field.value)
  }
  output
}
