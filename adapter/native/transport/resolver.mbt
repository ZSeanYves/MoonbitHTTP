///|
/// Native hostname resolver. The async socket API exposes the first address
/// for each requested family, so this adapter returns at most one IPv4 and one
/// IPv6 address while still enforcing the caller's result bound.
/// If neither family resolves, the original first failure is returned.
pub struct NativeResolver(Unit)

///|
pub fn NativeResolver::new() -> NativeResolver {
  NativeResolver(())
}

///|
async fn resolve_family(
  host : String,
  protocol : @socket.IpProtocolPreference,
) -> Result[@types.IpAddress, @transport_api.TransportError] {
  let address = @socket.Addr::resolve(host, port=0, protocol~) catch {
    error => return Err(native_transport_error(Resolve, error))
  }
  match ip_from_socket_addr(address) {
    Some(address) => Ok(address)
    None => Err(Failed(Resolve, "resolved address cannot be represented"))
  }
}

///|
fn append_unique_address(
  addresses : Array[@types.IpAddress],
  candidate : @types.IpAddress,
  max_results : Int,
) -> Unit {
  guard addresses.length() < max_results else { return }
  for address in addresses {
    if address == candidate {
      return
    }
  }
  addresses.push(candidate)
}

///|
async fn resolve_native_host(
  host : String,
  max_results : Int,
  lookup~ : async (String, @socket.IpProtocolPreference) -> Result[
    @types.IpAddress,
    @transport_api.TransportError,
  ],
) -> Result[Array[@types.IpAddress], @transport_api.TransportError] {
  let addresses : Array[@types.IpAddress] = []
  let mut first_failure : @transport_api.TransportError? = None
  let protocols : Array[@socket.IpProtocolPreference] = [OnlyV4, OnlyV6]
  for protocol in protocols {
    if addresses.length() >= max_results {
      break
    }
    match lookup(host, protocol) {
      Ok(address) => append_unique_address(addresses, address, max_results)
      Err(Cancelled) => return Err(Cancelled)
      Err(Timeout(operation)) => return Err(Timeout(operation))
      Err(error) => if first_failure is None { first_failure = Some(error) }
    }
  }
  if addresses.is_empty() {
    Err(
      first_failure.unwrap_or(
        Failed(Resolve, "hostname resolution returned no addresses"),
      ),
    )
  } else {
    Ok(addresses)
  }
}

///|
pub impl @transport_api.NameResolver for NativeResolver with fn resolve(
  _self,
  host,
  options,
) {
  match options.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match @types.IpAddress::parse(host) {
    Ok(address) => return Ok([address])
    Err(_) => ()
  }
  match
    native_io(Resolve, options.timeout_ms, async fn() {
      resolve_native_host(host, options.max_results, lookup=resolve_family)
    }) {
    Ok(result) => result
    Err(error) => Err(error)
  }
}
