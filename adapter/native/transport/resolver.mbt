///|
/// Resolves all representable unscoped addresses in system preference order.
pub struct NativeResolver(Unit)

///|
pub fn NativeResolver::new() -> NativeResolver {
  NativeResolver(())
}

///|
priv type Lookup

///|
#borrow(host)
extern "C" fn lookup_start(host : Bytes) -> Lookup = "moon_http_lookup_start"

///|
#borrow(self)
extern "C" fn Lookup::status(self : Lookup) -> Int32 = "moon_http_lookup_status"

///|
#borrow(self)
extern "C" fn Lookup::error(self : Lookup) -> Int32 = "moon_http_lookup_error"

///|
#borrow(self)
extern "C" fn Lookup::message(self : Lookup) -> Bytes = "moon_http_lookup_message"

///|
#borrow(self)
extern "C" fn Lookup::next(self : Lookup) -> Bytes = "moon_http_lookup_next"

///|
#borrow(self)
extern "C" fn Lookup::release(self : Lookup) -> Unit = "moon_http_lookup_release"

///|
fn collect_addresses(
  max_results : Int32,
  next : () -> Bytes,
) -> Result[Array[@types.IpAddress], @transport_api.TransportError] {
  let addresses = []
  while addresses.length() < max_results {
    let bytes = next()
    if bytes.is_empty() {
      break
    }
    if @types.IpAddress::parse(@utf8.decode_lossy(bytes)) is Ok(address) &&
      !addresses.contains(address) {
      addresses.push(address)
    }
  }
  if addresses.is_empty() {
    Err(Failed(Resolve, "hostname resolution returned no addresses"))
  } else {
    Ok(addresses)
  }
}

///|
async fn resolve_native_host(
  host : String,
  max_results : Int32,
) -> Result[Array[@types.IpAddress], @transport_api.TransportError] {
  let name = @utf8.encode(host)
  let mut delay = 1
  for ;; {
    let job = lookup_start(name)
    defer job.release()
    match job.status() {
      -2 => {
        @async.sleep(delay)
        delay = (delay * 2).min(16)
        continue
      }
      -1 => return Err(Failed(Resolve, "could not start hostname resolution"))
      _ => ()
    }
    while job.status() == 0 {
      @async.sleep(delay)
      delay = (delay * 2).min(16)
    }
    let code = job.error()
    if code != 0 {
      return Err(
        SystemFailure(Resolve, code, @utf8.decode_lossy(job.message())),
      )
    }
    return collect_addresses(max_results, () => job.next())
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
      resolve_native_host(host, options.max_results)
    }) {
    Ok(result) => result
    Err(error) => Err(error)
  }
}
