///|
const NATIVE_TLS_OBSERVATION_LIMIT : Int = 64 * 1024

///|
const NATIVE_TLS_RECORD_LIMIT : Int = 18 * 1024

///|
priv struct NativeTlsMetadata {
  version : @tls.TlsVersion
  cipher_suite : String
  alpn : String?
}

///|
priv struct NativeTlsObserver {
  records : Array[Byte]
  handshake : Array[Byte]
  mut record_offset : Int
  mut metadata : NativeTlsMetadata?
  mut failure : String?
}

///|
fn NativeTlsObserver::new() -> NativeTlsObserver {
  {
    records: [],
    handshake: [],
    record_offset: 0,
    metadata: None,
    failure: None,
  }
}

///|
fn native_tls_u16(input : Array[Byte], offset : Int) -> Int {
  (input[offset].to_int() << 8) | input[offset + 1].to_int()
}

///|
fn native_tls_u24(input : Array[Byte], offset : Int) -> Int {
  (input[offset].to_int() << 16) |
  (input[offset + 1].to_int() << 8) |
  input[offset + 2].to_int()
}

///|
fn native_tls_cipher_name(cipher : Int) -> String {
  match cipher {
    0x1301 => "TLS_AES_128_GCM_SHA256"
    0x1302 => "TLS_AES_256_GCM_SHA384"
    0x1303 => "TLS_CHACHA20_POLY1305_SHA256"
    0xc02b => "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256"
    0xc02c => "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384"
    0xc02f => "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"
    0xc030 => "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384"
    0xcca8 => "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256"
    0xcca9 => "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256"
    _ => "0x" + cipher.to_string(radix=16).pad_start(4, '0')
  }
}

///|
fn native_tls_parse_alpn(
  input : Array[Byte],
  start : Int,
  length : Int,
) -> Result[String, String] {
  let end = start + length
  if length < 4 || end > input.length() {
    return Err("malformed ALPN extension")
  }
  let list_length = native_tls_u16(input, start)
  if list_length != length - 2 {
    return Err("malformed ALPN protocol list")
  }
  let protocol_length = input[start + 2].to_int()
  if protocol_length == 0 || protocol_length != list_length - 1 {
    return Err("server selected an invalid ALPN protocol")
  }
  let protocol_bytes : Array[Byte] = []
  for index in (start + 3)..<end {
    protocol_bytes.push(input[index])
  }
  try @utf8.decode(Bytes::from_array(protocol_bytes)) catch {
    _ => Err("server selected a non-UTF-8 ALPN protocol")
  } noraise {
    protocol => Ok(protocol)
  }
}

///|
fn native_tls_parse_server_hello(
  input : Array[Byte],
) -> Result[NativeTlsMetadata?, String] {
  if input.length() < 4 {
    return Ok(None)
  }
  if input[0] != b'\x02' {
    return Err("first TLS handshake message was not ServerHello")
  }
  let message_length = native_tls_u24(input, 1)
  if message_length > NATIVE_TLS_OBSERVATION_LIMIT - 4 {
    return Err("ServerHello exceeded observation limit")
  }
  let message_end = 4 + message_length
  if input.length() < message_end {
    return Ok(None)
  }
  // legacy_version + random + session-id length + cipher + compression
  if message_length < 38 {
    return Err("truncated ServerHello")
  }
  let legacy_version = native_tls_u16(input, 4)
  let session_id_length = input[38].to_int()
  let mut cursor = 39 + session_id_length
  if cursor + 3 > message_end {
    return Err("truncated ServerHello session or cipher")
  }
  let cipher = native_tls_u16(input, cursor)
  cursor += 2
  if input[cursor] != b'\x00' {
    return Err("server selected a non-null compression method")
  }
  cursor += 1
  let mut selected_version = legacy_version
  let mut alpn : String? = None
  let mut saw_supported_version = false
  let mut saw_alpn = false
  if cursor < message_end {
    if cursor + 2 > message_end {
      return Err("truncated ServerHello extension length")
    }
    let extensions_length = native_tls_u16(input, cursor)
    cursor += 2
    if cursor + extensions_length != message_end {
      return Err("invalid ServerHello extension length")
    }
    while cursor < message_end {
      if cursor + 4 > message_end {
        return Err("truncated ServerHello extension")
      }
      let extension_type = native_tls_u16(input, cursor)
      let extension_length = native_tls_u16(input, cursor + 2)
      cursor += 4
      if extension_length > message_end - cursor {
        return Err("ServerHello extension exceeded message boundary")
      }
      match extension_type {
        0x002b => {
          if saw_supported_version || extension_length != 2 {
            return Err("invalid supported_versions selection")
          }
          saw_supported_version = true
          selected_version = native_tls_u16(input, cursor)
        }
        0x0010 => {
          if saw_alpn {
            return Err("duplicate ALPN extension")
          }
          saw_alpn = true
          alpn = Some(
            match native_tls_parse_alpn(input, cursor, extension_length) {
              Ok(protocol) => protocol
              Err(error) => return Err(error)
            },
          )
        }
        _ => ()
      }
      cursor += extension_length
    }
  }
  let version : @tls.TlsVersion = match selected_version {
    0x0303 => Tls12
    0x0304 => Tls13
    _ => return Err("host TLS negotiated an unsupported protocol version")
  }
  Ok(Some({ version, cipher_suite: native_tls_cipher_name(cipher), alpn, }))
}

///|
fn NativeTlsObserver::fail(self : NativeTlsObserver, message : String) -> Unit {
  if self.failure is None {
    self.failure = Some(message)
  }
}

///|
fn NativeTlsObserver::feed(self : NativeTlsObserver, input : Bytes) -> Unit {
  if self.metadata is Some(_) || self.failure is Some(_) {
    return
  }
  if self.records.length() > NATIVE_TLS_OBSERVATION_LIMIT - input.length() {
    self.fail("TLS handshake exceeded observation limit")
    return
  }
  for byte in input {
    self.records.push(byte)
  }
  while self.record_offset + 5 <= self.records.length() {
    let offset = self.record_offset
    let content_type = self.records[offset].to_int()
    let record_major = self.records[offset + 1].to_int()
    let record_minor = self.records[offset + 2].to_int()
    let record_length = native_tls_u16(self.records, offset + 3)
    if record_major != 3 || record_minor < 1 || record_minor > 4 {
      self.fail("invalid TLS record version")
      return
    }
    if record_length > NATIVE_TLS_RECORD_LIMIT {
      self.fail("TLS record exceeded observation limit")
      return
    }
    let record_end = offset + 5 + record_length
    if record_end > self.records.length() {
      return
    }
    match content_type {
      20 => () // Compatibility ChangeCipherSpec may precede a retry.
      21 => {
        self.fail("TLS alert received before ServerHello")
        return
      }
      22 =>
        for index in (offset + 5)..<record_end {
          self.handshake.push(self.records[index])
        }
      _ => {
        self.fail("unexpected TLS record before ServerHello")
        return
      }
    }
    self.record_offset = record_end
    match native_tls_parse_server_hello(self.handshake) {
      Ok(None) => ()
      Ok(Some(metadata)) => {
        self.metadata = Some(metadata)
        return
      }
      Err(error) => {
        self.fail(error)
        return
      }
    }
  }
}

///|
fn NativeTlsObserver::result(
  self : NativeTlsObserver,
) -> Result[NativeTlsMetadata, String] {
  match self.failure {
    Some(error) => Err(error)
    None =>
      match self.metadata {
        Some(metadata) => Ok(metadata)
        None =>
          Err("host TLS completed without observable ServerHello metadata")
      }
  }
}

///|
fn native_tls_version_allowed(
  options : @tls.TlsOptions,
  version : @tls.TlsVersion,
) -> Bool {
  if options.min_version == Tls13 && version == Tls12 {
    return false
  }
  match options.max_version {
    Some(Tls12) if version == Tls13 => false
    _ => true
  }
}
