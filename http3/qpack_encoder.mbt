///|
priv struct QpackEncoderEntry {
  absolute_index : Int64
  field : QpackField
  size : Int
  mut references : Int
}

///|
priv struct QpackPendingSection {
  required_insert_count : Int64
  references : Array[Int64]
}

///|
/// Pending-section metadata is small but attacker-controlled in count. Keep a
/// fixed accounting unit for the section and one word per dynamic reference.
fn qpack_pending_section_cost(section : QpackPendingSection) -> Int {
  let references = section.references.length()
  if references > (@int.MAX_VALUE - 16) / 8 {
    @int.MAX_VALUE
  } else {
    16 + references * 8
  }
}

///|
pub struct QpackEncoder {
  limits : QpackLimits
  priv mut entries : Array[QpackEncoderEntry]
  mut table_size : Int
  mut capacity : Int
  mut total_inserts : Int64
  mut known_received_count : Int64
  priv pending : Map[Int64, Array[QpackPendingSection]]
  mut pending_bytes : Int
  mut decoder_buffer : Array[Byte]
  mut failure : Http3Error?
}

///|
pub fn QpackEncoder::new(
  limits? : QpackLimits = QpackLimits::defaults(),
) -> Result[QpackEncoder, Http3Error] {
  match limits.validate() {
    Ok(_) =>
      Ok({
        limits,
        entries: [],
        table_size: 0,
        capacity: 0,
        total_inserts: 0L,
        known_received_count: 0L,
        pending: Map([]),
        pending_bytes: 0,
        decoder_buffer: [],
        failure: None,
      })
    Err(error) => Err(error)
  }
}

///|
pub fn QpackEncoder::total_inserts(self : QpackEncoder) -> Int64 {
  self.total_inserts
}

///|
pub fn QpackEncoder::known_received_count(self : QpackEncoder) -> Int64 {
  self.known_received_count
}

///|
/// Returns the bounded memory budget currently held by unacknowledged dynamic
/// field sections.
pub fn QpackEncoder::pending_bytes(self : QpackEncoder) -> Int {
  self.pending_bytes
}

///|
pub fn QpackEncoder::table_size(self : QpackEncoder) -> Int {
  self.table_size
}

///|
fn QpackEncoder::lookup_absolute(
  self : QpackEncoder,
  absolute_index : Int64,
) -> QpackEncoderEntry? {
  for entry in self.entries {
    if entry.absolute_index == absolute_index {
      return Some(entry)
    }
  }
  None
}

///|
fn QpackEncoder::find_exact(
  self : QpackEncoder,
  field : QpackField,
) -> QpackEncoderEntry? {
  for entry in self.entries {
    if entry.field.name == field.name && entry.field.value == field.value {
      return Some(entry)
    }
  }
  None
}

///|
fn QpackEncoder::find_name(
  self : QpackEncoder,
  name : String,
) -> QpackEncoderEntry? {
  for entry in self.entries {
    if entry.field.name == name {
      return Some(entry)
    }
  }
  None
}

///|
fn QpackEncoder::can_evict_to(self : QpackEncoder, target_size : Int) -> Bool {
  let mut size = self.table_size
  let mut index = self.entries.length()
  while size > target_size && index > 0 {
    index -= 1
    let entry = self.entries[index]
    if entry.references != 0 {
      return false
    }
    size -= entry.size
  }
  size <= target_size
}

///|
fn QpackEncoder::evict_to(self : QpackEncoder, target_size : Int) -> Unit {
  while self.table_size > target_size && !self.entries.is_empty() {
    let last = self.entries[self.entries.length() - 1]
    self.table_size -= last.size
    ignore(self.entries.pop())
  }
}

///|
pub fn QpackEncoder::set_capacity(
  self : QpackEncoder,
  capacity : Int,
) -> Result[Bytes, Http3Error] {
  if capacity < 0 || capacity > self.limits.max_table_capacity {
    return Err(
      Http3LimitExceeded(
        "QPACK encoder table capacity",
        self.limits.max_table_capacity,
      ),
    )
  }
  if !self.can_evict_to(capacity) {
    return Err(
      Http3ConnectionError(
        QpackEncoderStreamError,
        "capacity reduction would evict referenced entries",
      ),
    )
  }
  self.capacity = capacity
  self.evict_to(capacity)
  let encoded = qpack_encode_integer(5, capacity.to_int64())
  encoded[0] = (encoded[0].to_int() | 0x20).to_byte()
  Ok(Bytes::from_array(encoded))
}

///|
fn QpackEncoder::insert_local(
  self : QpackEncoder,
  field : QpackField,
) -> Result[Int64, Http3Error] {
  let size = qpack_field_size(field)
  if size > self.capacity {
    return Err(Http3LimitExceeded("QPACK dynamic entry", self.capacity))
  }
  let target = self.capacity - size
  if !self.can_evict_to(target) {
    return Err(
      Http3ConnectionError(
        QpackEncoderStreamError,
        "dynamic table insertion would evict referenced entries",
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
  self.evict_to(target)
  let absolute_index = self.total_inserts
  let next : Array[QpackEncoderEntry] = [
    { absolute_index, field, size, references: 0, },
  ]
  for entry in self.entries {
    next.push(entry)
  }
  self.entries = next
  self.table_size += size
  self.total_inserts += 1L
  Ok(absolute_index)
}

///|
pub fn QpackEncoder::insert(
  self : QpackEncoder,
  field : QpackField,
  use_huffman? : Bool = true,
) -> Result[(Bytes, Int64), Http3Error] {
  match qpack_validate_field(field) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if field.sensitive || qpack_sensitive_name(field.name) {
    return Err(
      Http3ConnectionError(
        QpackEncoderStreamError,
        "sensitive fields cannot enter the dynamic table",
      ),
    )
  }
  let instruction : Array[Byte] = []
  let static_name = qpack_static_find_name(field.name)
  if static_name >= 0 {
    let encoded = qpack_encode_integer(6, static_name.to_int64())
    encoded[0] = (encoded[0].to_int() | 0xc0).to_byte()
    qpack_append(instruction, encoded)
  } else {
    match self.find_name(field.name) {
      Some(entry) => {
        let relative = self.total_inserts - entry.absolute_index - 1L
        let encoded = qpack_encode_integer(6, relative)
        encoded[0] = (encoded[0].to_int() | 0x80).to_byte()
        qpack_append(instruction, encoded)
      }
      None =>
        qpack_append(
          instruction,
          qpack_encode_string(
            @utf8.encode(field.name),
            5,
            0x20,
            0x40,
            use_huffman,
          ),
        )
    }
  }
  qpack_append(
    instruction,
    qpack_encode_string(field.value, 7, 0x80, 0, use_huffman),
  )
  if instruction.length() > self.limits.max_instruction_buffer_bytes {
    return Err(
      Http3LimitExceeded(
        "QPACK encoder instruction",
        self.limits.max_instruction_buffer_bytes,
      ),
    )
  }
  let index = match self.insert_local(field) {
    Ok(result) => result
    Err(error) => return Err(error)
  }
  Ok((Bytes::from_array(instruction), index))
}

///|
fn qpack_unique_reference(references : Array[Int64], index : Int64) -> Unit {
  for existing in references {
    if existing == index {
      return
    }
  }
  references.push(index)
}

///|
pub fn QpackEncoder::encode_field_section(
  self : QpackEncoder,
  stream_id : Int64,
  fields : Array[QpackField],
  use_huffman? : Bool = true,
) -> Result[Bytes, Http3Error] {
  if stream_id < 0L {
    return Err(
      Http3ConnectionError(
        QpackEncoderStreamError,
        "negative request stream ID",
      ),
    )
  }
  if fields.length() > self.limits.max_field_count {
    return Err(
      Http3LimitExceeded("QPACK field count", self.limits.max_field_count),
    )
  }
  let body : Array[Byte] = []
  let references : Array[Int64] = []
  let mut required_insert_count = 0L
  let base = self.total_inserts
  let mut decoded_size = 0
  for field in fields {
    match qpack_validate_field(field) {
      Ok(_) => ()
      Err(error) => return Err(error)
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
    let sensitive = field.sensitive || qpack_sensitive_name(field.name)
    let static_exact = qpack_static_find_exact(field)
    if static_exact >= 0 && !sensitive {
      let encoded = qpack_encode_integer(6, static_exact.to_int64())
      encoded[0] = (encoded[0].to_int() | 0xc0).to_byte()
      qpack_append(body, encoded)
      continue
    }
    let dynamic_exact = if sensitive { None } else { self.find_exact(field) }
    if dynamic_exact is Some(entry) &&
      entry.absolute_index < self.known_received_count {
      let relative = base - entry.absolute_index - 1L
      let encoded = qpack_encode_integer(6, relative)
      encoded[0] = (encoded[0].to_int() | 0x80).to_byte()
      qpack_append(body, encoded)
      qpack_unique_reference(references, entry.absolute_index)
      required_insert_count = required_insert_count.max(
        entry.absolute_index + 1L,
      )
      continue
    }
    let static_name = qpack_static_find_name(field.name)
    if static_name >= 0 {
      let encoded = qpack_encode_integer(4, static_name.to_int64())
      encoded[0] = (encoded[0].to_int() |
      0x50 |
      (if sensitive { 0x20 } else { 0 })).to_byte()
      qpack_append(body, encoded)
    } else {
      let dynamic_name = if sensitive {
        None
      } else {
        self.find_name(field.name)
      }
      if dynamic_name is Some(entry) &&
        entry.absolute_index < self.known_received_count {
        let relative = base - entry.absolute_index - 1L
        let encoded = qpack_encode_integer(4, relative)
        encoded[0] = (encoded[0].to_int() | 0x40).to_byte()
        qpack_append(body, encoded)
        qpack_unique_reference(references, entry.absolute_index)
        required_insert_count = required_insert_count.max(
          entry.absolute_index + 1L,
        )
      } else {
        let leading = 0x20 | (if sensitive { 0x10 } else { 0 })
        qpack_append(
          body,
          qpack_encode_string(
            @utf8.encode(field.name),
            3,
            0x08,
            leading,
            use_huffman,
          ),
        )
      }
    }
    qpack_append(
      body,
      qpack_encode_string(field.value, 7, 0x80, 0, use_huffman),
    )
  }
  let encoded_insert_count = if required_insert_count == 0L {
    0L
  } else {
    let max_entries = (self.limits.max_table_capacity / 32).to_int64()
    if max_entries == 0L {
      return Err(
        Http3ConnectionError(
          QpackEncoderStreamError,
          "dynamic reference with zero table capacity",
        ),
      )
    }
    required_insert_count % (2L * max_entries) + 1L
  }
  let output = qpack_encode_integer(8, encoded_insert_count)
  let delta_base = base - required_insert_count
  qpack_append(output, qpack_encode_integer(7, delta_base))
  qpack_append(output, body)
  if output.length() > self.limits.max_encoded_field_section_bytes {
    return Err(
      Http3LimitExceeded(
        "QPACK encoded field section",
        self.limits.max_encoded_field_section_bytes,
      ),
    )
  }
  if !references.is_empty() {
    let section : QpackPendingSection = { required_insert_count, references, }
    let section_bytes = qpack_pending_section_cost(section)
    if self.pending_bytes >
      self.limits.max_instruction_buffer_bytes - section_bytes {
      return Err(
        Http3LimitExceeded(
          "QPACK pending field sections",
          self.limits.max_instruction_buffer_bytes,
        ),
      )
    }
    for absolute_index in references {
      if self.lookup_absolute(absolute_index) is None {
        return Err(
          Http3ConnectionError(
            QpackEncoderStreamError,
            "referenced entry was evicted",
          ),
        )
      }
    }
    for absolute_index in references {
      match self.lookup_absolute(absolute_index) {
        Some(entry) => entry.references += 1
        None =>
          return Err(
            Http3ConnectionError(
              QpackEncoderStreamError,
              "referenced entry was evicted",
            ),
          )
      }
    }
    let sections = match self.pending.get(stream_id) {
      Some(value) => value
      None => []
    }
    sections.push(section)
    self.pending.set(stream_id, sections)
    self.pending_bytes += section_bytes
  }
  Ok(Bytes::from_array(output))
}

///|
fn QpackEncoder::release_section(
  self : QpackEncoder,
  section : QpackPendingSection,
  acknowledge_inserts : Bool,
) -> Result[Unit, Http3Error] {
  for absolute_index in section.references {
    match self.lookup_absolute(absolute_index) {
      Some(entry) if entry.references > 0 => entry.references -= 1
      _ =>
        return Err(
          Http3ConnectionError(
            QpackDecoderStreamError,
            "decoder acknowledged an unknown reference",
          ),
        )
    }
  }
  self.pending_bytes -= qpack_pending_section_cost(section)
  if acknowledge_inserts {
    self.known_received_count = self.known_received_count.max(
      section.required_insert_count,
    )
  }
  Ok(())
}

///|
fn QpackEncoder::acknowledge_section(
  self : QpackEncoder,
  stream_id : Int64,
) -> Result[Unit, Http3Error] {
  let sections = match self.pending.get(stream_id) {
    Some(value) if !value.is_empty() => value
    _ =>
      return Err(
        Http3ConnectionError(
          QpackDecoderStreamError,
          "unexpected QPACK Section Acknowledgment",
        ),
      )
  }
  let section = sections[0]
  let remaining : Array[QpackPendingSection] = []
  for index in 1..<sections.length() {
    remaining.push(sections[index])
  }
  if remaining.is_empty() {
    self.pending.remove(stream_id)
  } else {
    self.pending.set(stream_id, remaining)
  }
  self.release_section(section, true)
}

///|
fn QpackEncoder::cancel_stream_references(
  self : QpackEncoder,
  stream_id : Int64,
) -> Result[Unit, Http3Error] {
  match self.pending.get(stream_id) {
    None => Ok(())
    Some(sections) => {
      self.pending.remove(stream_id)
      for section in sections {
        match self.release_section(section, false) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
      }
      Ok(())
    }
  }
}
