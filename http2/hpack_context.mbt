///|
pub struct HpackTable {
  mut entries : Array[HpackHeader]
  mut size : Int
  mut max_size : Int
}

///|
pub fn HpackTable::new(max_size? : Int = 4096) -> HpackTable {
  { entries: [], size: 0, max_size }
}

///|
fn hpack_entry_size(header : HpackHeader) -> Int {
  @utf8.encode(header.name).length() + @utf8.encode(header.value).length() + 32
}

///|
fn HpackTable::evict(self : HpackTable) -> Unit {
  while self.size > self.max_size && !self.entries.is_empty() {
    let last = self.entries[self.entries.length() - 1]
    self.size -= hpack_entry_size(last)
    ignore(self.entries.pop())
  }
}

///|
pub fn HpackTable::resize(self : HpackTable, max_size : Int) -> Unit {
  self.max_size = max_size
  self.evict()
}

///|
pub fn HpackTable::insert(self : HpackTable, header : HpackHeader) -> Unit {
  let size = hpack_entry_size(header)
  if size > self.max_size {
    self.entries.clear()
    self.size = 0
    return
  }
  let next : Array[HpackHeader] = [header]
  for entry in self.entries {
    next.push(entry)
  }
  self.entries = next
  self.size += size
  self.evict()
}

///|
pub fn HpackTable::length(self : HpackTable) -> Int {
  self.entries.length()
}

///|
fn HpackTable::get_dynamic(self : HpackTable, index : Int) -> HpackHeader? {
  let offset = index - 62
  if offset < 0 || offset >= self.entries.length() {
    None
  } else {
    Some(self.entries[offset])
  }
}

///|
pub struct HpackContext {
  table : HpackTable
  max_allowed_table_size : Int
  max_header_list_size : Int
}

///|
pub fn HpackContext::new(
  max_table_size? : Int = 4096,
  max_header_list_size? : Int = 64 * 1024,
) -> HpackContext {
  {
    table: HpackTable::new(max_size=max_table_size),
    max_allowed_table_size: max_table_size,
    max_header_list_size,
  }
}

///|
fn HpackContext::lookup(self : HpackContext, index : Int) -> HpackHeader? {
  if index <= 0 {
    return None
  }
  if index <= 61 {
    match hpack_static_get(index) {
      Some((name, value)) => Some({ name, value })
      None => None
    }
  } else {
    self.table.get_dynamic(index)
  }
}

///|
fn HpackContext::decode_name(
  self : HpackContext,
  block : Array[Byte],
  pos : Int,
  prefix : Int,
) -> Result[(String, Int), String] {
  let (index, used) = match decode_integer(block, pos, prefix) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if index == 0 {
    let (name, string_used) = match decode_string(block, pos + used) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    Ok((name, used + string_used))
  } else {
    match self.lookup(index) {
      Some(header) => Ok((header.name, used))
      None => Err("hpack: invalid name index")
    }
  }
}

///|
pub fn HpackContext::decode(
  self : HpackContext,
  encoded : BytesView,
) -> Result[Array[HpackHeader], H2ProtocolError] {
  let block = encoded.to_owned().to_array()
  let headers : Array[HpackHeader] = []
  let mut pos = 0
  let mut list_size = 0
  let mut saw_field = false
  while pos < block.length() {
    let byte = block[pos].to_int() & 0xff
    let header = if (byte & 0x80) != 0 {
      let (index, used) = match decode_integer(block, pos, 7) {
        Ok(value) => value
        Err(message) => return Err(ConnectionError(CompressionError, message))
      }
      pos += used
      saw_field = true
      match self.lookup(index) {
        Some(value) => value
        None =>
          return Err(
            ConnectionError(CompressionError, "invalid indexed header"),
          )
      }
    } else if (byte & 0xc0) == 0x40 {
      let (name, used) = match self.decode_name(block, pos, 6) {
        Ok(value) => value
        Err(message) => return Err(ConnectionError(CompressionError, message))
      }
      pos += used
      let (value, value_used) = match decode_string(block, pos) {
        Ok(value) => value
        Err(message) => return Err(ConnectionError(CompressionError, message))
      }
      pos += value_used
      let header : HpackHeader = { name, value }
      self.table.insert(header)
      saw_field = true
      header
    } else if (byte & 0xe0) == 0x20 {
      if saw_field {
        return Err(
          ConnectionError(
            CompressionError,
            "dynamic table update follows a header field",
          ),
        )
      }
      let (size, used) = match decode_integer(block, pos, 5) {
        Ok(value) => value
        Err(message) => return Err(ConnectionError(CompressionError, message))
      }
      if size > self.max_allowed_table_size {
        return Err(
          ConnectionError(
            CompressionError,
            "dynamic table size exceeds SETTINGS",
          ),
        )
      }
      self.table.resize(size)
      pos += used
      continue
    } else {
      let prefix = 4
      let (name, used) = match self.decode_name(block, pos, prefix) {
        Ok(value) => value
        Err(message) => return Err(ConnectionError(CompressionError, message))
      }
      pos += used
      let (value, value_used) = match decode_string(block, pos) {
        Ok(value) => value
        Err(message) => return Err(ConnectionError(CompressionError, message))
      }
      pos += value_used
      saw_field = true
      { name, value }
    }
    list_size += hpack_entry_size(header)
    if list_size > self.max_header_list_size {
      return Err(
        ConnectionError(EnhanceYourCalm, "decoded header list is too large"),
      )
    }
    headers.push(header)
  }
  Ok(headers)
}

///|
fn append_encoded(out : Array[Byte], bytes : Array[Byte]) -> Unit {
  for byte in bytes {
    out.push(byte)
  }
}

///|
fn HpackContext::find_exact(self : HpackContext, header : HpackHeader) -> Int {
  for index in 1..<=61 {
    if hpack_static_get(index) is Some((name, value)) &&
      name == header.name &&
      value == header.value {
      return index
    }
  }
  for index, entry in self.table.entries {
    if entry.name == header.name && entry.value == header.value {
      return 62 + index
    }
  }
  0
}

///|
fn HpackContext::find_name(self : HpackContext, name : String) -> Int {
  let static_index = hpack_static_find_name(name)
  if static_index != 0 {
    return static_index
  }
  for index, entry in self.table.entries {
    if entry.name == name {
      return 62 + index
    }
  }
  0
}

///|
pub fn HpackContext::encode_incremental(
  self : HpackContext,
  headers : Array[HpackHeader],
) -> Result[Bytes, H2ProtocolError] {
  let out : Array[Byte] = []
  let mut list_size = 0
  for header in headers {
    list_size += hpack_entry_size(header)
    if list_size > self.max_header_list_size {
      return Err(
        ConnectionError(EnhanceYourCalm, "encoded header list is too large"),
      )
    }
    let exact = self.find_exact(header)
    if exact != 0 {
      let encoded = encode_integer(7, exact)
      encoded[0] = (encoded[0].to_int() | 0x80).to_byte()
      append_encoded(out, encoded)
      continue
    }
    let name_index = self.find_name(header.name)
    let encoded_name = encode_integer(6, name_index)
    encoded_name[0] = (encoded_name[0].to_int() | 0x40).to_byte()
    append_encoded(out, encoded_name)
    if name_index == 0 {
      append_encoded(out, encode_string(header.name))
    }
    append_encoded(out, encode_string(header.value))
    self.table.insert(header)
  }
  Ok(Bytes::from_array(out))
}

///|
pub fn HpackContext::table_length(self : HpackContext) -> Int {
  self.table.length()
}
