///|
/// Shared finite resource limits. Protocol and policy layers may impose
/// smaller local limits, but must never silently exceed these values.
pub(all) struct Limits {
  max_start_line : Int
  max_header_line : Int
  max_header_count : Int
  max_header_bytes : Int
  max_body_bytes : Int
  max_buffer_bytes : Int
  max_streams : Int
  max_concurrent_requests : Int
  max_dynamic_table_bytes : Int
  max_datagram_bytes : Int
} derive(Debug, Eq)

///|
pub(all) suberror LimitsError {
  InvalidLimit(field~ : String, value~ : Int)
} derive(Debug, Eq)

///|
pub fn Limits::new(
  max_start_line? : Int = 8192,
  max_header_line? : Int = 8192,
  max_header_count? : Int = 100,
  max_header_bytes? : Int = 64 * 1024,
  max_body_bytes? : Int = 16 * 1024 * 1024,
  max_buffer_bytes? : Int = 256 * 1024,
  max_streams? : Int = 100,
  max_concurrent_requests? : Int = 100,
  max_dynamic_table_bytes? : Int = 4096,
  max_datagram_bytes? : Int = 65527,
) -> Result[Limits, LimitsError] {
  let limits = {
    max_start_line,
    max_header_line,
    max_header_count,
    max_header_bytes,
    max_body_bytes,
    max_buffer_bytes,
    max_streams,
    max_concurrent_requests,
    max_dynamic_table_bytes,
    max_datagram_bytes,
  }
  match limits.validate() {
    Ok(_) => Ok(limits)
    Err(error) => Err(error)
  }
}

///|
pub fn Limits::defaults() -> Limits {
  {
    max_start_line: 8192,
    max_header_line: 8192,
    max_header_count: 100,
    max_header_bytes: 64 * 1024,
    max_body_bytes: 16 * 1024 * 1024,
    max_buffer_bytes: 256 * 1024,
    max_streams: 100,
    max_concurrent_requests: 100,
    max_dynamic_table_bytes: 4096,
    max_datagram_bytes: 65527,
  }
}

///|
pub fn Limits::validate(self : Limits) -> Result[Unit, LimitsError] {
  let configured : Array[(String, Int, Bool)] = [
    ("max_start_line", self.max_start_line, false),
    ("max_header_line", self.max_header_line, false),
    ("max_header_count", self.max_header_count, true),
    ("max_header_bytes", self.max_header_bytes, true),
    ("max_body_bytes", self.max_body_bytes, true),
    ("max_buffer_bytes", self.max_buffer_bytes, false),
    ("max_streams", self.max_streams, false),
    ("max_concurrent_requests", self.max_concurrent_requests, false),
    ("max_dynamic_table_bytes", self.max_dynamic_table_bytes, true),
    ("max_datagram_bytes", self.max_datagram_bytes, false),
  ]
  for entry in configured {
    let (field, value, allow_zero) = entry
    if value < 0 || (!allow_zero && value == 0) {
      return Err(InvalidLimit(field~, value~))
    }
  }
  if self.max_header_line > self.max_header_bytes {
    return Err(
      InvalidLimit(field="max_header_line", value=self.max_header_line),
    )
  }
  if self.max_start_line > self.max_buffer_bytes {
    return Err(InvalidLimit(field="max_start_line", value=self.max_start_line))
  }
  if self.max_header_line > self.max_buffer_bytes {
    return Err(
      InvalidLimit(field="max_header_line", value=self.max_header_line),
    )
  }
  Ok(())
}
