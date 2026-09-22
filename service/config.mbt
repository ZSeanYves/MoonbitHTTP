///|
pub(all) suberror ServiceConfigError {
  InvalidLimits(@types.LimitsError)
  InvalidReadSize(Int)
  InvalidBodyQueueCapacity(Int)
  InvalidConcurrentStreams(Int)
  InvalidTimeout(String, Int)
} derive(Debug, Eq)

///|
fn validate_timeout(
  name : String,
  value : Int?,
) -> Result[Unit, ServiceConfigError] {
  match value {
    Some(timeout) if timeout <= 0 => Err(InvalidTimeout(name, timeout))
    _ => Ok(())
  }
}

///|
pub fn ServerConfig::validate(
  self : ServerConfig,
) -> Result[Unit, ServiceConfigError] {
  match self.limits.validate() {
    Ok(_) => ()
    Err(error) => return Err(InvalidLimits(error))
  }
  if self.read_size <= 0 || self.read_size > self.limits.max_buffer_bytes {
    return Err(InvalidReadSize(self.read_size))
  }
  if self.body_queue_capacity <= 0 {
    return Err(InvalidBodyQueueCapacity(self.body_queue_capacity))
  }
  match validate_timeout("read", self.read_timeout_ms) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  validate_timeout("write", self.write_timeout_ms)
}

///|
pub fn H2ClientConfig::validate(
  self : H2ClientConfig,
) -> Result[Unit, ServiceConfigError] {
  match self.limits.validate() {
    Ok(_) => ()
    Err(error) => return Err(InvalidLimits(error))
  }
  if self.read_size <= 0 || self.read_size > self.limits.max_buffer_bytes {
    return Err(InvalidReadSize(self.read_size))
  }
  if self.body_queue_capacity <= 0 {
    return Err(InvalidBodyQueueCapacity(self.body_queue_capacity))
  }
  if self.max_concurrent_streams <= 0 ||
    self.max_concurrent_streams > self.limits.max_concurrent_requests {
    return Err(InvalidConcurrentStreams(self.max_concurrent_streams))
  }
  match validate_timeout("read", self.read_timeout_ms) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  validate_timeout("write", self.write_timeout_ms)
}
