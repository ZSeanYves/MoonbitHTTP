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
