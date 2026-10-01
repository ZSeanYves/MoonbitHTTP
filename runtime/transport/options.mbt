///|
pub(all) struct ConnectOptions {
  timeout_ms : Int?
  idle_timeout_ms : Int?
  local_host : String?
  local_port : Int?
} derive(Debug, Eq)

///|
pub fn ConnectOptions::defaults() -> ConnectOptions {
  {
    timeout_ms: Some(10000),
    idle_timeout_ms: Some(60000),
    local_host: None,
    local_port: None,
  }
}

///|
pub fn ConnectOptions::validate(
  self : ConnectOptions,
) -> Result[Unit, ConnectOptionsError] {
  match self.timeout_ms {
    Some(value) if value <= 0 => return Err(InvalidTimeout)
    _ => ()
  }
  match self.idle_timeout_ms {
    Some(value) if value <= 0 => return Err(InvalidTimeout)
    _ => ()
  }
  match self.local_port {
    Some(value) if value < 0 || value > 65535 => return Err(InvalidLocalPort)
    _ => ()
  }
  match self.local_host {
    Some(value) if Endpoint::new("tcp", value, 1) is Err(_) =>
      return Err(InvalidLocalHost)
    _ => ()
  }
  Ok(())
}

///|
pub(all) struct ResolveOptions {
  timeout_ms : Int?
  max_results : Int
} derive(Debug, Eq)

///|
pub fn ResolveOptions::defaults() -> ResolveOptions {
  { timeout_ms: Some(10000), max_results: 16, }
}

///|
pub fn ResolveOptions::validate(
  self : ResolveOptions,
) -> Result[Unit, TransportError] {
  match self.timeout_ms {
    Some(value) if value <= 0 => return Err(InvalidResolveOptions)
    _ => ()
  }
  if self.max_results <= 0 {
    return Err(InvalidResolveOptions)
  }
  Ok(())
}
