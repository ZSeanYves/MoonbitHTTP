///|
priv enum QpackParseError {
  QpackParseNeedMore
  QpackParseMalformed(String)
}

///|
pub(all) struct QpackField {
  name : String
  value : Bytes
  sensitive : Bool
} derive(Eq)

///|
pub impl @debug.Debug for QpackField with fn to_repr(self) {
  @debug.Repr::record({
    "name": @debug.Repr::string(self.name),
    "value": if self.sensitive {
      @debug.Repr::literal("<redacted>")
    } else {
      @debug.Repr::opaque_(
        "Bytes",
        @debug.Repr::array(
          self.value
          .to_array()
          .map(byte => @debug.Repr::integer(byte.to_int().to_string())),
        ),
      )
    },
    "sensitive": @debug.Repr::bool(self.sensitive),
  })
}

///|
fn qpack_sensitive_name(name : String) -> Bool {
  name == "authorization" ||
  name == "proxy-authorization" ||
  name == "cookie" ||
  name == "set-cookie"
}

///|
fn qpack_valid_pseudo_name(name : String) -> Bool {
  if name.length() < 2 || name[0] != ':' {
    return false
  }
  for index in 1..<name.length() {
    let byte = name[index]
    if !((byte >= 'a' && byte <= 'z') ||
      (byte >= '0' && byte <= '9') ||
      byte == '-' ||
      byte == '_' ||
      byte == '.') {
      return false
    }
  }
  true
}

///|
fn qpack_validate_field(field : QpackField) -> Result[Unit, Http3Error] {
  if field.name.has_prefix(":") {
    if !qpack_valid_pseudo_name(field.name) {
      return Err(
        Http3ConnectionError(H3MessageError, "invalid HTTP/3 pseudo-field name"),
      )
    }
  } else {
    match @types.HeaderName::parse(field.name) {
      Ok(parsed) if parsed.value == field.name => ()
      _ =>
        return Err(
          Http3ConnectionError(
            H3MessageError,
            "invalid or uppercase HTTP/3 field name",
          ),
        )
    }
  }
  match @types.HeaderValue::from_bytes(field.value) {
    Ok(_) => Ok(())
    Err(_) =>
      Err(Http3ConnectionError(H3MessageError, "invalid HTTP/3 field value"))
  }
}

///|
pub fn QpackField::new(
  name : String,
  value : Bytes,
  sensitive? : Bool = false,
) -> Result[QpackField, Http3Error] {
  let field = {
    name,
    value,
    sensitive: sensitive || qpack_sensitive_name(name),
  }
  match qpack_validate_field(field) {
    Ok(_) => Ok(field)
    Err(error) => Err(error)
  }
}

///|
pub fn QpackField::from_strings(
  name : String,
  value : String,
  sensitive? : Bool = false,
) -> Result[QpackField, Http3Error] {
  QpackField::new(name, @utf8.encode(value), sensitive~)
}

// RFC 9204 Appendix A. QPACK indices are zero-based.

///|
fn qpack_static_get(index : Int) -> (String, String)? {
  match index {
    0 => Some((":authority", ""))
    1 => Some((":path", "/"))
    2 => Some(("age", "0"))
    3 => Some(("content-disposition", ""))
    4 => Some(("content-length", "0"))
    5 => Some(("cookie", ""))
    6 => Some(("date", ""))
    7 => Some(("etag", ""))
    8 => Some(("if-modified-since", ""))
    9 => Some(("if-none-match", ""))
    10 => Some(("last-modified", ""))
    11 => Some(("link", ""))
    12 => Some(("location", ""))
    13 => Some(("referer", ""))
    14 => Some(("set-cookie", ""))
    15 => Some((":method", "CONNECT"))
    16 => Some((":method", "DELETE"))
    17 => Some((":method", "GET"))
    18 => Some((":method", "HEAD"))
    19 => Some((":method", "OPTIONS"))
    20 => Some((":method", "POST"))
    21 => Some((":method", "PUT"))
    22 => Some((":scheme", "http"))
    23 => Some((":scheme", "https"))
    24 => Some((":status", "103"))
    25 => Some((":status", "200"))
    26 => Some((":status", "304"))
    27 => Some((":status", "404"))
    28 => Some((":status", "503"))
    29 => Some(("accept", "*/*"))
    30 => Some(("accept", "application/dns-message"))
    31 => Some(("accept-encoding", "gzip, deflate, br"))
    32 => Some(("accept-ranges", "bytes"))
    33 => Some(("access-control-allow-headers", "cache-control"))
    34 => Some(("access-control-allow-headers", "content-type"))
    35 => Some(("access-control-allow-origin", "*"))
    36 => Some(("cache-control", "max-age=0"))
    37 => Some(("cache-control", "max-age=2592000"))
    38 => Some(("cache-control", "max-age=604800"))
    39 => Some(("cache-control", "no-cache"))
    40 => Some(("cache-control", "no-store"))
    41 => Some(("cache-control", "public, max-age=31536000"))
    42 => Some(("content-encoding", "br"))
    43 => Some(("content-encoding", "gzip"))
    44 => Some(("content-type", "application/dns-message"))
    45 => Some(("content-type", "application/javascript"))
    46 => Some(("content-type", "application/json"))
    47 => Some(("content-type", "application/x-www-form-urlencoded"))
    48 => Some(("content-type", "image/gif"))
    49 => Some(("content-type", "image/jpeg"))
    50 => Some(("content-type", "image/png"))
    51 => Some(("content-type", "text/css"))
    52 => Some(("content-type", "text/html; charset=utf-8"))
    53 => Some(("content-type", "text/plain"))
    54 => Some(("content-type", "text/plain;charset=utf-8"))
    55 => Some(("range", "bytes=0-"))
    56 => Some(("strict-transport-security", "max-age=31536000"))
    57 =>
      Some(("strict-transport-security", "max-age=31536000; includesubdomains"))
    58 =>
      Some(
        (
          "strict-transport-security", "max-age=31536000; includesubdomains; preload",
        ),
      )
    59 => Some(("vary", "accept-encoding"))
    60 => Some(("vary", "origin"))
    61 => Some(("x-content-type-options", "nosniff"))
    62 => Some(("x-xss-protection", "1; mode=block"))
    63 => Some((":status", "100"))
    64 => Some((":status", "204"))
    65 => Some((":status", "206"))
    66 => Some((":status", "302"))
    67 => Some((":status", "400"))
    68 => Some((":status", "403"))
    69 => Some((":status", "421"))
    70 => Some((":status", "425"))
    71 => Some((":status", "500"))
    72 => Some(("accept-language", ""))
    73 => Some(("access-control-allow-credentials", "FALSE"))
    74 => Some(("access-control-allow-credentials", "TRUE"))
    75 => Some(("access-control-allow-headers", "*"))
    76 => Some(("access-control-allow-methods", "get"))
    77 => Some(("access-control-allow-methods", "get, post, options"))
    78 => Some(("access-control-allow-methods", "options"))
    79 => Some(("access-control-expose-headers", "content-length"))
    80 => Some(("access-control-request-headers", "content-type"))
    81 => Some(("access-control-request-method", "get"))
    82 => Some(("access-control-request-method", "post"))
    83 => Some(("alt-svc", "clear"))
    84 => Some(("authorization", ""))
    85 =>
      Some(
        (
          "content-security-policy", "script-src 'none'; object-src 'none'; base-uri 'none'",
        ),
      )
    86 => Some(("early-data", "1"))
    87 => Some(("expect-ct", ""))
    88 => Some(("forwarded", ""))
    89 => Some(("if-range", ""))
    90 => Some(("origin", ""))
    91 => Some(("purpose", "prefetch"))
    92 => Some(("server", ""))
    93 => Some(("timing-allow-origin", "*"))
    94 => Some(("upgrade-insecure-requests", "1"))
    95 => Some(("user-agent", ""))
    96 => Some(("x-forwarded-for", ""))
    97 => Some(("x-frame-options", "deny"))
    98 => Some(("x-frame-options", "sameorigin"))
    _ => None
  }
}

///|
fn qpack_static_field(index : Int64) -> QpackField? {
  if index < 0L || index > 98L {
    return None
  }
  match qpack_static_get(index.to_int()) {
    Some((name, value)) =>
      Some({ name, value: @utf8.encode(value), sensitive: false, })
    None => None
  }
}

///|
fn qpack_static_find_exact(field : QpackField) -> Int {
  for index in 0..<99 {
    if qpack_static_get(index) is Some((name, value)) &&
      name == field.name &&
      @utf8.encode(value) == field.value {
      return index
    }
  }
  -1
}

///|
fn qpack_static_find_name(name : String) -> Int {
  for index in 0..<99 {
    if qpack_static_get(index) is Some((candidate, _)) && candidate == name {
      return index
    }
  }
  -1
}

///|
fn qpack_decode_integer(
  input : BytesView,
  prefix_bits : Int,
) -> Result[(Int64, Int), QpackParseError] {
  if input.is_empty() {
    return Err(QpackParseNeedMore)
  }
  if prefix_bits < 1 || prefix_bits > 8 {
    return Err(QpackParseMalformed("invalid QPACK integer prefix"))
  }
  let prefix_max = (1 << prefix_bits) - 1
  let mut value = (input[0].to_int() & prefix_max).to_int64()
  if value < prefix_max.to_int64() {
    return Ok((value, 1))
  }
  let mut offset = 1
  let mut shift = 0
  while offset < input.length() {
    let byte = input[offset].to_int()
    let digit = (byte & 0x7f).to_int64()
    if shift > 56 || digit > (@quic.QUIC_MAX_VARINT - value) >> shift {
      return Err(QpackParseMalformed("QPACK integer overflow"))
    }
    value += digit << shift
    offset += 1
    if (byte & 0x80) == 0 {
      return Ok((value, offset))
    }
    shift += 7
  }
  Err(QpackParseNeedMore)
}

///|
fn qpack_encode_integer(prefix_bits : Int, value : Int64) -> Array[Byte] {
  let prefix_max = (1 << prefix_bits) - 1
  let output : Array[Byte] = []
  if value < prefix_max.to_int64() {
    output.push(value.to_byte())
    return output
  }
  output.push(prefix_max.to_byte())
  let mut remaining = value - prefix_max.to_int64()
  while remaining >= 128L {
    output.push(((remaining & 0x7fL) | 0x80L).to_byte())
    remaining = remaining >> 7
  }
  output.push(remaining.to_byte())
  output
}

///|
fn qpack_decode_string(
  input : BytesView,
  prefix_bits : Int,
  huffman_mask : Int,
  max_decoded_bytes : Int,
) -> Result[(Bytes, Int), QpackParseError] {
  if input.is_empty() {
    return Err(QpackParseNeedMore)
  }
  let huffman = (input[0].to_int() & huffman_mask) != 0
  let (length64, prefix_used) = match qpack_decode_integer(input, prefix_bits) {
    Ok(result) => result
    Err(error) => return Err(error)
  }
  if length64 > max_decoded_bytes.to_int64() ||
    length64 > @int.MAX_VALUE.to_int64() {
    return Err(QpackParseMalformed("QPACK string exceeds configured limit"))
  }
  let length = length64.to_int()
  if prefix_used > input.length() || length > input.length() - prefix_used {
    return Err(QpackParseNeedMore)
  }
  let encoded = input[prefix_used:prefix_used + length].to_owned()
  let decoded = if huffman {
    match @http2.hpack_huffman_decode(encoded.to_array()) {
      Ok(value) => Bytes::from_array(value)
      Err(message) =>
        return Err(
          QpackParseMalformed("invalid QPACK Huffman string: " + message),
        )
    }
  } else {
    encoded
  }
  if decoded.length() > max_decoded_bytes {
    return Err(
      QpackParseMalformed("decoded QPACK string exceeds configured limit"),
    )
  }
  Ok((decoded, prefix_used + length))
}

///|
fn qpack_encode_string(
  raw : BytesView,
  prefix_bits : Int,
  huffman_mask : Int,
  leading_bits : Int,
  use_huffman : Bool,
) -> Array[Byte] {
  let raw_bytes = raw.to_owned().to_array()
  let (payload, huffman) = if use_huffman {
    match @http2.hpack_huffman_encode(raw_bytes) {
      Ok(encoded) if encoded.length() < raw_bytes.length() => (encoded, true)
      _ => (raw_bytes, false)
    }
  } else {
    (raw_bytes, false)
  }
  let output = qpack_encode_integer(prefix_bits, payload.length().to_int64())
  output[0] = (output[0].to_int() |
  leading_bits |
  (if huffman { huffman_mask } else { 0 })).to_byte()
  for byte in payload {
    output.push(byte)
  }
  output
}

///|
fn qpack_field_size(field : QpackField) -> Int {
  @utf8.encode(field.name).length() + field.value.length() + 32
}

///|
fn qpack_append(output : Array[Byte], encoded : Array[Byte]) -> Unit {
  for byte in encoded {
    output.push(byte)
  }
}

///|
pub fn qpack_encode_static(
  fields : Array[QpackField],
  max_field_section_bytes? : Int = 64 * 1024,
  max_field_count? : Int = 100,
  use_huffman? : Bool = true,
) -> Result[Bytes, Http3Error] {
  if max_field_section_bytes < 0 || max_field_count < 0 {
    return Err(
      Http3LimitExceeded("QPACK field section", max_field_section_bytes),
    )
  }
  if fields.length() > max_field_count {
    return Err(Http3LimitExceeded("QPACK field count", max_field_count))
  }
  let output : Array[Byte] = [0, 0]
  let mut decoded_size = 0
  for field in fields {
    match qpack_validate_field(field) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    let size = qpack_field_size(field)
    if decoded_size > max_field_section_bytes ||
      size > max_field_section_bytes - decoded_size {
      return Err(
        Http3LimitExceeded(
          "QPACK decoded field section", max_field_section_bytes,
        ),
      )
    }
    decoded_size += size
    let sensitive = field.sensitive || qpack_sensitive_name(field.name)
    let exact = qpack_static_find_exact(field)
    if exact >= 0 && !sensitive {
      let encoded = qpack_encode_integer(6, exact.to_int64())
      encoded[0] = (encoded[0].to_int() | 0xc0).to_byte()
      qpack_append(output, encoded)
    } else {
      let name_index = qpack_static_find_name(field.name)
      if name_index >= 0 {
        let encoded = qpack_encode_integer(4, name_index.to_int64())
        encoded[0] = (encoded[0].to_int() |
        0x50 |
        (if sensitive { 0x20 } else { 0 })).to_byte()
        qpack_append(output, encoded)
      } else {
        let leading = 0x20 | (if sensitive { 0x10 } else { 0 })
        qpack_append(
          output,
          qpack_encode_string(
            @utf8.encode(field.name),
            3,
            0x08,
            leading,
            use_huffman,
          ),
        )
      }
      qpack_append(
        output,
        qpack_encode_string(field.value, 7, 0x80, 0, use_huffman),
      )
    }
    if output.length() > max_field_section_bytes {
      return Err(
        Http3LimitExceeded(
          "QPACK encoded field section", max_field_section_bytes,
        ),
      )
    }
  }
  Ok(Bytes::from_array(output))
}

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

///|
pub struct QpackDynamicEntry {
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
  mut entries : Array[QpackDynamicEntry]
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
fn qpack_parse_error(
  error : QpackParseError,
  code : H3ErrorCode,
  context : String,
) -> Http3Error {
  match error {
    QpackParseNeedMore => Http3ConnectionError(code, context + " is truncated")
    QpackParseMalformed(message) =>
      Http3ConnectionError(code, context + ": " + message)
  }
}

///|
fn qpack_decode_name(raw : Bytes) -> Result[String, QpackParseError] {
  let name = @utf8.decode(raw) catch {
    _ => return Err(QpackParseMalformed("field name is not valid UTF-8"))
  }
  let field = { name, value: b"", sensitive: false, }
  match qpack_validate_field(field) {
    Ok(_) => Ok(name)
    Err(_) => Err(QpackParseMalformed("invalid or uppercase field name"))
  }
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
fn QpackDecoder::parse_encoder_instruction(
  self : QpackDecoder,
) -> Result[Int, QpackParseError] {
  if self.encoder_buffer.is_empty() {
    return Err(QpackParseNeedMore)
  }
  let input = Bytes::from_array(self.encoder_buffer)
  let first = input[0].to_int()
  if (first & 0x80) != 0 {
    let is_static = (first & 0x40) != 0
    let (index, name_used) = match qpack_decode_integer(input, 6) {
      Ok(result) => result
      Err(error) => return Err(error)
    }
    let name = if is_static {
      match qpack_static_field(index) {
        Some(field) => field.name
        None => return Err(QpackParseMalformed("invalid static name index"))
      }
    } else {
      match self.relative_field(index) {
        Some(field) => field.name
        None => return Err(QpackParseMalformed("invalid dynamic name index"))
      }
    }
    let (value, value_used) = match
      qpack_decode_string(
        input[name_used:],
        7,
        0x80,
        self.limits.max_decoded_field_section_bytes,
      ) {
      Ok(result) => result
      Err(error) => return Err(error)
    }
    match self.insert(name, value) {
      Ok(_) => Ok(name_used + value_used)
      Err(Http3ConnectionError(_, message)) => Err(QpackParseMalformed(message))
      Err(_) => Err(QpackParseMalformed("dynamic table insertion failed"))
    }
  } else if (first & 0xc0) == 0x40 {
    let (name_bytes, name_used) = match
      qpack_decode_string(
        input,
        5,
        0x20,
        self.limits.max_decoded_field_section_bytes,
      ) {
      Ok(result) => result
      Err(error) => return Err(error)
    }
    let name = match qpack_decode_name(name_bytes) {
      Ok(result) => result
      Err(error) => return Err(error)
    }
    let (value, value_used) = match
      qpack_decode_string(
        input[name_used:],
        7,
        0x80,
        self.limits.max_decoded_field_section_bytes,
      ) {
      Ok(result) => result
      Err(error) => return Err(error)
    }
    match self.insert(name, value) {
      Ok(_) => Ok(name_used + value_used)
      Err(Http3ConnectionError(_, message)) => Err(QpackParseMalformed(message))
      Err(_) => Err(QpackParseMalformed("dynamic table insertion failed"))
    }
  } else if (first & 0xe0) == 0x20 {
    let (capacity, used) = match qpack_decode_integer(input, 5) {
      Ok(result) => result
      Err(error) => return Err(error)
    }
    match self.set_capacity(capacity) {
      Ok(_) => Ok(used)
      Err(Http3ConnectionError(_, message)) => Err(QpackParseMalformed(message))
      Err(_) => Err(QpackParseMalformed("invalid dynamic table capacity"))
    }
  } else {
    let (index, used) = match qpack_decode_integer(input, 5) {
      Ok(result) => result
      Err(error) => return Err(error)
    }
    let field = match self.relative_field(index) {
      Some(value) => value
      None => return Err(QpackParseMalformed("invalid Duplicate index"))
    }
    match self.insert(field.name, field.value) {
      Ok(_) => Ok(used)
      Err(Http3ConnectionError(_, message)) => Err(QpackParseMalformed(message))
      Err(_) => Err(QpackParseMalformed("dynamic table duplication failed"))
    }
  }
}

///|
pub fn QpackDecoder::feed_encoder_stream(
  self : QpackDecoder,
  bytes : BytesView,
) -> Result[Unit, Http3Error] {
  if self.failure is Some(error) {
    return Err(error)
  }
  if self.encoder_buffer.length() > self.limits.max_instruction_buffer_bytes ||
    bytes.length() >
    self.limits.max_instruction_buffer_bytes - self.encoder_buffer.length() {
    let error = Http3LimitExceeded(
      "QPACK encoder instruction buffer",
      self.limits.max_instruction_buffer_bytes,
    )
    self.failure = Some(error)
    return Err(error)
  }
  h3_append_bytes(self.encoder_buffer, bytes)
  while !self.encoder_buffer.is_empty() {
    match self.parse_encoder_instruction() {
      Err(QpackParseNeedMore) => return Ok(())
      Err(error) => {
        let error = qpack_parse_error(
          error,
          QpackEncoderStreamError,
          "QPACK encoder instruction",
        )
        self.failure = Some(error)
        return Err(error)
      }
      Ok(used) => {
        let remaining : Array[Byte] = []
        for index in used..<self.encoder_buffer.length() {
          remaining.push(self.encoder_buffer[index])
        }
        self.encoder_buffer = remaining
      }
    }
  }
  Ok(())
}

///|
pub fn QpackDecoder::finish_encoder_stream(
  self : QpackDecoder,
) -> Result[Unit, Http3Error] {
  if self.failure is Some(error) {
    return Err(error)
  }
  if !self.encoder_buffer.is_empty() {
    let error = Http3ConnectionError(
      QpackEncoderStreamError,
      "QPACK encoder stream ended mid-instruction",
    )
    self.failure = Some(error)
    return Err(error)
  }
  Ok(())
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

///|
pub struct QpackEncoderEntry {
  absolute_index : Int64
  field : QpackField
  size : Int
  mut references : Int
}

///|
pub struct QpackPendingSection {
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
  mut entries : Array[QpackEncoderEntry]
  mut table_size : Int
  mut capacity : Int
  mut total_inserts : Int64
  mut known_received_count : Int64
  pending : Map[Int64, Array[QpackPendingSection]]
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

///|
fn QpackEncoder::parse_decoder_instruction(
  self : QpackEncoder,
) -> Result[Int, QpackParseError] {
  if self.decoder_buffer.is_empty() {
    return Err(QpackParseNeedMore)
  }
  let input = Bytes::from_array(self.decoder_buffer)
  let first = input[0].to_int()
  if (first & 0x80) != 0 {
    let (stream_id, used) = match qpack_decode_integer(input, 7) {
      Ok(result) => result
      Err(error) => return Err(error)
    }
    match self.acknowledge_section(stream_id) {
      Ok(_) => Ok(used)
      Err(Http3ConnectionError(_, message)) => Err(QpackParseMalformed(message))
      Err(_) => Err(QpackParseMalformed("invalid Section Acknowledgment"))
    }
  } else if (first & 0x40) != 0 {
    let (stream_id, used) = match qpack_decode_integer(input, 6) {
      Ok(result) => result
      Err(error) => return Err(error)
    }
    match self.cancel_stream_references(stream_id) {
      Ok(_) => Ok(used)
      Err(Http3ConnectionError(_, message)) => Err(QpackParseMalformed(message))
      Err(_) => Err(QpackParseMalformed("invalid Stream Cancellation"))
    }
  } else {
    let (increment, used) = match qpack_decode_integer(input, 6) {
      Ok(result) => result
      Err(error) => return Err(error)
    }
    if increment == 0L ||
      increment > self.total_inserts - self.known_received_count {
      return Err(QpackParseMalformed("invalid Insert Count Increment"))
    }
    self.known_received_count += increment
    Ok(used)
  }
}

///|
pub fn QpackEncoder::feed_decoder_stream(
  self : QpackEncoder,
  bytes : BytesView,
) -> Result[Unit, Http3Error] {
  if self.failure is Some(error) {
    return Err(error)
  }
  if self.decoder_buffer.length() > self.limits.max_instruction_buffer_bytes ||
    bytes.length() >
    self.limits.max_instruction_buffer_bytes - self.decoder_buffer.length() {
    let error = Http3LimitExceeded(
      "QPACK decoder instruction buffer",
      self.limits.max_instruction_buffer_bytes,
    )
    self.failure = Some(error)
    return Err(error)
  }
  h3_append_bytes(self.decoder_buffer, bytes)
  while !self.decoder_buffer.is_empty() {
    match self.parse_decoder_instruction() {
      Err(QpackParseNeedMore) => return Ok(())
      Err(error) => {
        let error = qpack_parse_error(
          error,
          QpackDecoderStreamError,
          "QPACK decoder instruction",
        )
        self.failure = Some(error)
        return Err(error)
      }
      Ok(used) => {
        let remaining : Array[Byte] = []
        for index in used..<self.decoder_buffer.length() {
          remaining.push(self.decoder_buffer[index])
        }
        self.decoder_buffer = remaining
      }
    }
  }
  Ok(())
}

///|
pub fn QpackEncoder::finish_decoder_stream(
  self : QpackEncoder,
) -> Result[Unit, Http3Error] {
  if self.failure is Some(error) {
    return Err(error)
  }
  if !self.decoder_buffer.is_empty() {
    let error = Http3ConnectionError(
      QpackDecoderStreamError,
      "QPACK decoder stream ended mid-instruction",
    )
    self.failure = Some(error)
    return Err(error)
  }
  Ok(())
}

///|
pub fn qpack_section_acknowledgment(
  stream_id : Int64,
) -> Result[Bytes, Http3Error] {
  if stream_id < 0L || stream_id > @quic.QUIC_MAX_VARINT {
    return Err(
      Http3ConnectionError(QpackDecoderStreamError, "invalid stream ID"),
    )
  }
  let encoded = qpack_encode_integer(7, stream_id)
  encoded[0] = (encoded[0].to_int() | 0x80).to_byte()
  Ok(Bytes::from_array(encoded))
}

///|
pub fn qpack_stream_cancellation(
  stream_id : Int64,
) -> Result[Bytes, Http3Error] {
  if stream_id < 0L || stream_id > @quic.QUIC_MAX_VARINT {
    return Err(
      Http3ConnectionError(QpackDecoderStreamError, "invalid stream ID"),
    )
  }
  let encoded = qpack_encode_integer(6, stream_id)
  encoded[0] = (encoded[0].to_int() | 0x40).to_byte()
  Ok(Bytes::from_array(encoded))
}

///|
pub fn qpack_insert_count_increment(
  increment : Int64,
) -> Result[Bytes, Http3Error] {
  if increment <= 0L || increment > @quic.QUIC_MAX_VARINT {
    return Err(
      Http3ConnectionError(
        QpackDecoderStreamError,
        "invalid insert count increment",
      ),
    )
  }
  Ok(Bytes::from_array(qpack_encode_integer(6, increment)))
}
