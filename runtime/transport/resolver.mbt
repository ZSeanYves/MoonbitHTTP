///|
fn resolver_ascii_lower(value : String) -> String {
  let bytes = @utf8.encode(value)
  let out = FixedArray::make(bytes.length(), b'0')
  for i in 0..<bytes.length() {
    let byte = bytes[i]
    out[i] = if byte >= b'A' && byte <= b'Z' {
      (byte.to_int() + 32).to_byte()
    } else {
      byte
    }
  }
  @utf8.decode(out.unsafe_reinterpret_as_bytes()) catch {
    _ => ""
  }
}

///|
pub(open) trait NameResolver {
  async fn resolve(Self, String, ResolveOptions) -> Result[
    Array[IpAddress],
    TransportError,
  ]
}

///|
pub struct StaticResolver {
  entries : Map[String, Array[IpAddress]]
}

///|
pub fn StaticResolver::new(
  entries : Array[(String, Array[IpAddress])],
) -> StaticResolver {
  let map = Map([])
  for (host, addresses) in entries {
    map.set(resolver_ascii_lower(host), addresses.copy())
  }
  { entries: map, }
}

///|
pub impl NameResolver for StaticResolver with fn resolve(self, host, options) {
  match options.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match self.entries.get(resolver_ascii_lower(host)) {
    Some(addresses) =>
      Ok(addresses[:addresses.length().min(options.max_results)].to_owned())
    None => Err(Failed(Resolve, "host was not found by resolver"))
  }
}

///|
/// Resolve a transport endpoint once, preserving address order and bounding the
/// result and wait even when the injected resolver does not enforce its options.
/// The caller authorizes the lookup and each numeric destination before use.
pub async fn resolve_endpoints(
  endpoint : Endpoint,
  lookup : async (String, ResolveOptions) -> Result[
    Array[IpAddress],
    TransportError,
  ],
  options~ : ResolveOptions = ResolveOptions::defaults(),
) -> Result[Array[Endpoint], TransportError] {
  match options.validate() {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  if IpAddress::parse(endpoint.host()) is Ok(_) {
    return Ok([endpoint])
  }
  let result = match options.timeout_ms {
    Some(timeout) =>
      @async.with_timeout(timeout, async fn() {
        lookup(endpoint.host(), options)
      }) catch {
        @async.TimeoutError => return Err(Timeout(Resolve))
        error => raise error
      }
    None => lookup(endpoint.host(), options)
  }
  let addresses = match result {
    Err(error) => return Err(error)
    Ok([]) => return Err(Failed(Resolve, "resolver returned no addresses"))
    Ok(addresses) => addresses
  }
  let candidates : Array[Endpoint] = []
  let seen : Set[String] = Set([])
  for index in 0..<addresses.length().min(options.max_results) {
    let address = addresses[index]
    if seen.add_and_check(address.value()) {
      candidates.push(endpoint.with_address(address))
    }
  }
  Ok(candidates)
}
