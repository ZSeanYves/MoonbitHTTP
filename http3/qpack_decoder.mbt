///|
priv struct QpackDynamicEntry {
  absolute_index : Int64
  field : QpackField
  size : Int
}

///|
pub(all) enum QpackDecodeResult {
  QpackDecoded(Array[QpackField], Bool)
  QpackBlocked(Int64)
} derive(Eq, Debug)

///|
pub struct QpackDecoder {
  limits : QpackLimits
  priv mut entries : Array[QpackDynamicEntry]
  mut table_size : Int
  mut capacity : Int
  mut total_inserts : Int64
  blocked : Map[Int64, Int64]
  mut encoder_buffer : Array[Byte]
  mut failure : Http3Error?
}

///|
pub fn QpackDecoder::new(
  limits? : QpackLimits = QpackLimits::defaults(),
) -> Result[QpackDecoder, Http3Error] {
  match limits.validate() {
    Ok(_) =>
      Ok({
        limits,
        entries: [],
        table_size: 0,
        capacity: 0,
        total_inserts: 0L,
        blocked: Map([]),
        encoder_buffer: [],
        failure: None,
      })
    Err(error) => Err(error)
  }
}

///|
pub fn QpackDecoder::total_inserts(self : QpackDecoder) -> Int64 {
  self.total_inserts
}

///|
pub fn QpackDecoder::table_size(self : QpackDecoder) -> Int {
  self.table_size
}

///|
pub fn QpackDecoder::capacity(self : QpackDecoder) -> Int {
  self.capacity
}

///|
pub fn QpackDecoder::blocked_stream_count(self : QpackDecoder) -> Int {
  self.blocked.length()
}

///|
fn QpackDecoder::lookup_absolute(
  self : QpackDecoder,
  absolute_index : Int64,
) -> QpackField? {
  for entry in self.entries {
    if entry.absolute_index == absolute_index {
      return Some(entry.field)
    }
  }
  None
}

///|
fn QpackDecoder::evict(self : QpackDecoder) -> Unit {
  while self.table_size > self.capacity && !self.entries.is_empty() {
    let last = self.entries[self.entries.length() - 1]
    self.table_size -= last.size
    ignore(self.entries.pop())
  }
}

///|
fn QpackDecoder::set_capacity(
  self : QpackDecoder,
  capacity : Int64,
) -> Result[Unit, Http3Error] {
  if capacity < 0L || capacity > self.limits.max_table_capacity.to_int64() {
    return Err(
      Http3ConnectionError(
        QpackEncoderStreamError,
        "dynamic table capacity exceeds SETTINGS_QPACK_MAX_TABLE_CAPACITY",
      ),
    )
  }
  self.capacity = capacity.to_int()
  self.evict()
  Ok(())
}

///|
fn QpackDecoder::insert(
  self : QpackDecoder,
  name : String,
  value : Bytes,
) -> Result[Unit, Http3Error] {
  let field = match QpackField::new(name, value) {
    Ok(result) => result
    Err(_) =>
      return Err(
        Http3ConnectionError(
          QpackEncoderStreamError,
          "encoder inserted an invalid field",
        ),
      )
  }
  let size = qpack_field_size(field)
  if size > self.capacity {
    return Err(
      Http3ConnectionError(
        QpackEncoderStreamError,
        "dynamic table entry exceeds current capacity",
      ),
    )
  }
  if self.total_inserts >= @quic.QUIC_MAX_VARINT {
    return Err(
      Http3ConnectionError(
        QpackEncoderStreamError,
        "QPACK insert count overflow",
      ),
    )
  }
  let next : Array[QpackDynamicEntry] = [
    { absolute_index: self.total_inserts, field, size, },
  ]
  for entry in self.entries {
    next.push(entry)
  }
  self.entries = next
  self.table_size += size
  self.total_inserts += 1L
  self.evict()
  Ok(())
}

///|
fn QpackDecoder::relative_field(
  self : QpackDecoder,
  relative : Int64,
) -> QpackField? {
  if relative < 0L || relative >= self.total_inserts {
    return None
  }
  self.lookup_absolute(self.total_inserts - relative - 1L)
}

///|
fn qpack_required_insert_count(
  encoded : Int64,
  max_table_capacity : Int,
  total_inserts : Int64,
) -> Result[Int64, QpackParseError] {
  if encoded == 0L {
    return Ok(0L)
  }
  let max_entries = (max_table_capacity / 32).to_int64()
  if max_entries == 0L {
    return Err(
      QpackParseMalformed(
        "non-zero Required Insert Count with zero table capacity",
      ),
    )
  }
  let full_range = 2L * max_entries
  if encoded > full_range {
    return Err(QpackParseMalformed("invalid encoded Required Insert Count"))
  }
  if total_inserts > @quic.QUIC_MAX_VARINT - max_entries {
    return Err(QpackParseMalformed("Required Insert Count overflow"))
  }
  let max_value = total_inserts + max_entries
  let max_wrapped = max_value / full_range * full_range
  let mut required = max_wrapped + encoded - 1L
  if required > max_value {
    if required <= full_range {
      return Err(QpackParseMalformed("invalid wrapped Required Insert Count"))
    }
    required -= full_range
  }
  if required == 0L {
    return Err(
      QpackParseMalformed("Required Insert Count zero was not encoded as zero"),
    )
  }
  Ok(required)
}

///|
fn QpackDecoder::resolve_field(
  self : QpackDecoder,
  index : Int64,
  is_static : Bool,
  post_base : Bool,
  base : Int64,
  required_insert_count : Int64,
) -> Result[QpackField, QpackParseError] {
  if is_static {
    return match qpack_static_field(index) {
      Some(field) => Ok(field)
      None => Err(QpackParseMalformed("invalid QPACK static table index"))
    }
  }
  let absolute = if post_base {
    if index > @quic.QUIC_MAX_VARINT - base {
      return Err(QpackParseMalformed("post-Base index overflow"))
    }
    base + index
  } else {
    if index >= base {
      return Err(
        QpackParseMalformed("relative dynamic index precedes table start"),
      )
    }
    base - index - 1L
  }
  if absolute < 0L || absolute >= required_insert_count {
    return Err(
      QpackParseMalformed("dynamic reference exceeds Required Insert Count"),
    )
  }
  match self.lookup_absolute(absolute) {
    Some(field) => Ok(field)
    None =>
      Err(
        QpackParseMalformed("dynamic table entry was evicted or not received"),
      )
  }
}

///|
fn QpackDecoder::track_blocked(
  self : QpackDecoder,
  stream_id : Int64,
  required_insert_count : Int64,
) -> Result[Unit, Http3Error] {
  if stream_id < 0L {
    return Err(
      Http3ConnectionError(
        QpackDecompressionFailed,
        "negative request stream ID",
      ),
    )
  }
  if self.blocked.get(stream_id) is None &&
    self.blocked.length() >= self.limits.max_blocked_streams {
    return Err(
      Http3ConnectionError(
        QpackDecompressionFailed,
        "SETTINGS_QPACK_BLOCKED_STREAMS limit exceeded",
      ),
    )
  }
  let required = match self.blocked.get(stream_id) {
    Some(previous) => previous.max(required_insert_count)
    None => required_insert_count
  }
  self.blocked.set(stream_id, required)
  Ok(())
}

///|
pub fn QpackDecoder::cancel_stream(
  self : QpackDecoder,
  stream_id : Int64,
) -> Unit {
  self.blocked.remove(stream_id)
}

///|
pub fn QpackDecoder::ready_blocked_streams(self : QpackDecoder) -> Array[Int64] {
  let ready : Array[Int64] = []
  for stream_id, required in self.blocked {
    if required <= self.total_inserts {
      ready.push(stream_id)
    }
  }
  ready
}

///|
pub fn QpackDecoder::decode_field_section(
  self : QpackDecoder,
  stream_id : Int64,
  encoded : BytesView,
) -> Result[QpackDecodeResult, Http3Error] {
  if encoded.length() > self.limits.max_encoded_field_section_bytes {
    return Err(
      Http3LimitExceeded(
        "QPACK encoded field section",
        self.limits.max_encoded_field_section_bytes,
      ),
    )
  }
  let (encoded_insert_count, insert_used) = match
    qpack_decode_integer(encoded, 8) {
    Ok(result) => result
    Err(error) =>
      return Err(
        qpack_parse_error(
          error,
          QpackDecompressionFailed,
          "field section prefix",
        ),
      )
  }
  let required_insert_count = match
    qpack_required_insert_count(
      encoded_insert_count,
      self.limits.max_table_capacity,
      self.total_inserts,
    ) {
    Ok(result) => result
    Err(error) =>
      return Err(
        qpack_parse_error(
          error,
          QpackDecompressionFailed,
          "Required Insert Count",
        ),
      )
  }
  if insert_used >= encoded.length() {
    return Err(
      Http3ConnectionError(
        QpackDecompressionFailed,
        "field section Base is missing",
      ),
    )
  }
  let sign = (encoded[insert_used].to_int() & 0x80) != 0
  let (delta_base, base_used) = match
    qpack_decode_integer(encoded[insert_used:], 7) {
    Ok(result) => result
    Err(error) =>
      return Err(
        qpack_parse_error(error, QpackDecompressionFailed, "field section Base"),
      )
  }
  let base = if sign {
    if required_insert_count <= delta_base {
      return Err(
        Http3ConnectionError(
          QpackDecompressionFailed,
          "field section Base is negative",
        ),
      )
    }
    required_insert_count - delta_base - 1L
  } else {
    if delta_base > @quic.QUIC_MAX_VARINT - required_insert_count {
      return Err(
        Http3ConnectionError(
          QpackDecompressionFailed,
          "field section Base overflow",
        ),
      )
    }
    required_insert_count + delta_base
  }
  if required_insert_count > self.total_inserts {
    match self.track_blocked(stream_id, required_insert_count) {
      Ok(_) => return Ok(QpackBlocked(required_insert_count))
      Err(error) => return Err(error)
    }
  }
  let fields : Array[QpackField] = []
  let mut decoded_size = 0
  let mut offset = insert_used + base_used
  while offset < encoded.length() {
    if fields.length() >= self.limits.max_field_count {
      return Err(
        Http3LimitExceeded("QPACK field count", self.limits.max_field_count),
      )
    }
    let first = encoded[offset].to_int()
    let mut field : QpackField = { name: "", value: b"", sensitive: false, }
    let mut used = 0
    if (first & 0x80) != 0 {
      let (index, index_used) = match
        qpack_decode_integer(encoded[offset:], 6) {
        Ok(result) => result
        Err(error) =>
          return Err(
            qpack_parse_error(
              error,
              QpackDecompressionFailed,
              "indexed field line",
            ),
          )
      }
      field = match
        self.resolve_field(
          index,
          (first & 0x40) != 0,
          false,
          base,
          required_insert_count,
        ) {
        Ok(result) => result
        Err(error) =>
          return Err(
            qpack_parse_error(
              error,
              QpackDecompressionFailed,
              "indexed field line",
            ),
          )
      }
      used = index_used
    } else if (first & 0xc0) == 0x40 {
      let (index, name_used) = match qpack_decode_integer(encoded[offset:], 4) {
        Ok(result) => result
        Err(error) =>
          return Err(
            qpack_parse_error(
              error,
              QpackDecompressionFailed,
              "literal name reference",
            ),
          )
      }
      let name_field = match
        self.resolve_field(
          index,
          (first & 0x10) != 0,
          false,
          base,
          required_insert_count,
        ) {
        Ok(result) => result
        Err(error) =>
          return Err(
            qpack_parse_error(
              error,
              QpackDecompressionFailed,
              "literal name reference",
            ),
          )
      }
      let (value, value_used) = match
        qpack_decode_string(
          encoded[offset + name_used:],
          7,
          0x80,
          self.limits.max_decoded_field_section_bytes,
        ) {
        Ok(result) => result
        Err(error) =>
          return Err(
            qpack_parse_error(
              error,
              QpackDecompressionFailed,
              "literal field value",
            ),
          )
      }
      field = { name: name_field.name, value, sensitive: (first & 0x20) != 0, }
      used = name_used + value_used
    } else if (first & 0xe0) == 0x20 {
      let sensitive = (first & 0x10) != 0
      let (name_bytes, name_used) = match
        qpack_decode_string(
          encoded[offset:],
          3,
          0x08,
          self.limits.max_decoded_field_section_bytes,
        ) {
        Ok(result) => result
        Err(error) =>
          return Err(
            qpack_parse_error(
              error,
              QpackDecompressionFailed,
              "literal field name",
            ),
          )
      }
      let name = match qpack_decode_name(name_bytes) {
        Ok(result) => result
        Err(error) =>
          return Err(
            qpack_parse_error(
              error,
              QpackDecompressionFailed,
              "literal field name",
            ),
          )
      }
      let (value, value_used) = match
        qpack_decode_string(
          encoded[offset + name_used:],
          7,
          0x80,
          self.limits.max_decoded_field_section_bytes,
        ) {
        Ok(result) => result
        Err(error) =>
          return Err(
            qpack_parse_error(
              error,
              QpackDecompressionFailed,
              "literal field value",
            ),
          )
      }
      field = { name, value, sensitive, }
      used = name_used + value_used
    } else if (first & 0xf0) == 0x10 {
      let (index, index_used) = match
        qpack_decode_integer(encoded[offset:], 4) {
        Ok(result) => result
        Err(error) =>
          return Err(
            qpack_parse_error(
              error,
              QpackDecompressionFailed,
              "post-Base indexed field",
            ),
          )
      }
      field = match
        self.resolve_field(index, false, true, base, required_insert_count) {
        Ok(result) => result
        Err(error) =>
          return Err(
            qpack_parse_error(
              error,
              QpackDecompressionFailed,
              "post-Base indexed field",
            ),
          )
      }
      used = index_used
    } else {
      let (index, name_used) = match qpack_decode_integer(encoded[offset:], 3) {
        Ok(result) => result
        Err(error) =>
          return Err(
            qpack_parse_error(
              error,
              QpackDecompressionFailed,
              "post-Base name reference",
            ),
          )
      }
      let name_field = match
        self.resolve_field(index, false, true, base, required_insert_count) {
        Ok(result) => result
        Err(error) =>
          return Err(
            qpack_parse_error(
              error,
              QpackDecompressionFailed,
              "post-Base name reference",
            ),
          )
      }
      let (value, value_used) = match
        qpack_decode_string(
          encoded[offset + name_used:],
          7,
          0x80,
          self.limits.max_decoded_field_section_bytes,
        ) {
        Ok(result) => result
        Err(error) =>
          return Err(
            qpack_parse_error(
              error,
              QpackDecompressionFailed,
              "literal field value",
            ),
          )
      }
      field = { name: name_field.name, value, sensitive: (first & 0x08) != 0, }
      used = name_used + value_used
    }
    match qpack_validate_field(field) {
      Ok(_) => ()
      Err(_) =>
        return Err(
          Http3StreamError(stream_id, H3MessageError, "invalid HTTP/3 field"),
        )
    }
    let size = qpack_field_size(field)
    if decoded_size > self.limits.max_decoded_field_section_bytes ||
      size > self.limits.max_decoded_field_section_bytes - decoded_size {
      return Err(
        Http3LimitExceeded(
          "QPACK decoded field section",
          self.limits.max_decoded_field_section_bytes,
        ),
      )
    }
    decoded_size += size
    fields.push(field)
    offset += used
  }
  self.blocked.remove(stream_id)
  Ok(QpackDecoded(fields, required_insert_count != 0L))
}
