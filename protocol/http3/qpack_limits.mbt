///|
pub(all) struct QpackLimits {
  max_encoded_field_section_bytes : Int
  max_decoded_field_section_bytes : Int
  max_field_count : Int
  max_table_capacity : Int
  max_blocked_streams : Int
  max_instruction_buffer_bytes : Int
} derive(Eq, Debug)

///|
pub fn QpackLimits::new(
  max_encoded_field_section_bytes? : Int = 64 * 1024,
  max_decoded_field_section_bytes? : Int = 64 * 1024,
  max_field_count? : Int = 100,
  max_table_capacity? : Int = 0,
  max_blocked_streams? : Int = 0,
  max_instruction_buffer_bytes? : Int = 64 * 1024,
) -> Result[QpackLimits, Http3Error] {
  let limits = {
    max_encoded_field_section_bytes,
    max_decoded_field_section_bytes,
    max_field_count,
    max_table_capacity,
    max_blocked_streams,
    max_instruction_buffer_bytes,
  }
  match limits.validate() {
    Ok(_) => Ok(limits)
    Err(error) => Err(error)
  }
}

///|
pub fn QpackLimits::defaults() -> QpackLimits {
  {
    max_encoded_field_section_bytes: 64 * 1024,
    max_decoded_field_section_bytes: 64 * 1024,
    max_field_count: 100,
    max_table_capacity: 0,
    max_blocked_streams: 0,
    max_instruction_buffer_bytes: 64 * 1024,
  }
}

///|
pub fn QpackLimits::from_http_limits(
  limits : @types.Limits,
  max_table_capacity? : Int = 0,
  max_blocked_streams? : Int = 0,
) -> Result[QpackLimits, Http3Error] {
  match limits.validate() {
    Ok(_) => ()
    Err(_) => return Err(Http3LimitExceeded("shared HTTP limits", 0))
  }
  QpackLimits::new(
    max_encoded_field_section_bytes=limits.max_header_bytes,
    max_decoded_field_section_bytes=limits.max_header_bytes,
    max_field_count=limits.max_header_count,
    max_table_capacity=max_table_capacity.min(limits.max_dynamic_table_bytes),
    max_blocked_streams=max_blocked_streams.min(limits.max_streams),
    max_instruction_buffer_bytes=limits.max_buffer_bytes,
  )
}

///|
pub fn QpackLimits::validate(self : QpackLimits) -> Result[Unit, Http3Error] {
  let configured : Array[(String, Int, Bool)] = [
    ("encoded field section", self.max_encoded_field_section_bytes, true),
    ("decoded field section", self.max_decoded_field_section_bytes, true),
    ("field count", self.max_field_count, true),
    ("dynamic table capacity", self.max_table_capacity, true),
    ("blocked streams", self.max_blocked_streams, true),
    ("instruction buffer", self.max_instruction_buffer_bytes, false),
  ]
  for entry in configured {
    let (name, value, allow_zero) = entry
    if value < 0 || (!allow_zero && value == 0) {
      return Err(Http3LimitExceeded(name, value))
    }
  }
  if self.max_table_capacity > self.max_instruction_buffer_bytes {
    return Err(
      Http3LimitExceeded("dynamic table capacity", self.max_table_capacity),
    )
  }
  Ok(())
}
