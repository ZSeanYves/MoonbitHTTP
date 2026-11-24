///|
#derive(Debug, Eq)
pub(all) suberror ServiceConfigError {
  InvalidLimits(@types.LimitsError)
  InvalidReadSize(Int32)
  InvalidBodyQueueCapacity(Int32)
  InvalidReceiveWindow(Int32)
  InvalidConcurrentStreams(Int32)
  InvalidTimeout(String, Int32)
}

///|
fn validate_timeout(
  name : String,
  value : Int32?,
) -> Result[Unit, ServiceConfigError] {
  match value {
    Some(timeout) if timeout <= 0 => Err(InvalidTimeout(name, timeout))
    _ => Ok(())
  }
}

///|
fn validate_read_limits(
  limits : @types.Limits,
  read_size : Int32,
) -> Result[Unit, ServiceConfigError] {
  if limits.validate() is Err(error) {
    return Err(InvalidLimits(error))
  }
  if read_size <= 0 || read_size > limits.max_buffer_bytes {
    return Err(InvalidReadSize(read_size))
  }
  Ok(())
}

///|
fn validate_io(
  limits : @types.Limits,
  read_size : Int32,
  queue_capacity : Int32,
  read_timeout : Int32?,
  write_timeout : Int32?,
) -> Result[Unit, ServiceConfigError] {
  if validate_read_limits(limits, read_size) is Err(error) {
    return Err(error)
  }
  if queue_capacity <= 0 {
    return Err(InvalidBodyQueueCapacity(queue_capacity))
  }
  if validate_timeout("read", read_timeout) is Err(error) {
    return Err(error)
  }
  validate_timeout("write", write_timeout)
}

///|
fn validate_receive_window(
  window : Int32,
  limits : @types.Limits,
) -> Result[Unit, ServiceConfigError] {
  if window <= 0 || window > limits.max_buffer_bytes {
    Err(InvalidReceiveWindow(window))
  } else {
    Ok(())
  }
}

///|
fn ServerConfig::validate_http1(
  self : ServerConfig,
) -> Result[Unit, ServiceConfigError] {
  validate_io(
    self.limits,
    self.read_size,
    self.body_queue_capacity,
    self.read_timeout_ms,
    self.write_timeout_ms,
  )
}

///|
pub fn ServerConfig::validate(
  self : ServerConfig,
) -> Result[Unit, ServiceConfigError] {
  match self.validate_http1() {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  if self.h2_eof_drain_timeout_ms <= 0 {
    return Err(InvalidTimeout("h2 EOF drain", self.h2_eof_drain_timeout_ms))
  }
  validate_receive_window(self.h2_receive_window_bytes, self.limits)
}

///|
pub fn Http2ClientConfig::validate(
  self : Http2ClientConfig,
) -> Result[Unit, ServiceConfigError] {
  if validate_io(
      self.limits,
      self.read_size,
      self.body_queue_capacity,
      self.read_timeout_ms,
      self.write_timeout_ms,
    )
    is Err(error) {
    return Err(error)
  }
  if self.max_concurrent_streams <= 0 ||
    self.max_concurrent_streams > self.limits.max_concurrent_requests {
    return Err(InvalidConcurrentStreams(self.max_concurrent_streams))
  }
  validate_receive_window(self.h2_receive_window_bytes, self.limits)
}

///|
fn require_initial_h2_settings(
  frame : @http2.H2Frame,
) -> Unit raise @http2.H2ProtocolError {
  if frame.header.typ != @http2.H2_FRAME_SETTINGS ||
    (frame.header.flags & @http2.H2_FLAGS_ACK) != 0 {
    raise ConnectionError(
      ProtocolError,
      "HTTP/2 connection preface requires initial SETTINGS",
    )
  }
}
