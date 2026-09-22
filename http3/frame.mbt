///|
pub const H3_FRAME_DATA : Int64 = 0L

///|
pub const H3_FRAME_HEADERS : Int64 = 1L

///|
pub const H3_FRAME_CANCEL_PUSH : Int64 = 3L

///|
pub const H3_FRAME_SETTINGS : Int64 = 4L

///|
pub const H3_FRAME_PUSH_PROMISE : Int64 = 5L

///|
pub const H3_FRAME_GOAWAY : Int64 = 7L

///|
pub const H3_FRAME_MAX_PUSH_ID : Int64 = 13L

///|
pub const H3_STREAM_CONTROL : Int64 = 0L

///|
pub const H3_STREAM_PUSH : Int64 = 1L

///|
pub const H3_STREAM_QPACK_ENCODER : Int64 = 2L

///|
pub const H3_STREAM_QPACK_DECODER : Int64 = 3L

///|
pub const H3_SETTINGS_QPACK_MAX_TABLE_CAPACITY : Int64 = 1L

///|
pub const H3_SETTINGS_MAX_FIELD_SECTION_SIZE : Int64 = 6L

///|
pub const H3_SETTINGS_QPACK_BLOCKED_STREAMS : Int64 = 7L

///|
pub const H3_SETTINGS_ENABLE_CONNECT_PROTOCOL : Int64 = 8L

///|
pub(all) enum H3ErrorCode {
  H3NoError
  H3GeneralProtocolError
  H3InternalError
  H3StreamCreationError
  H3ClosedCriticalStream
  H3FrameUnexpected
  H3FrameError
  H3ExcessiveLoad
  H3IdError
  H3SettingsError
  H3MissingSettings
  H3RequestRejected
  H3RequestCancelled
  H3RequestIncomplete
  H3MessageError
  H3ConnectError
  H3VersionFallback
  QpackDecompressionFailed
  QpackEncoderStreamError
  QpackDecoderStreamError
} derive(Eq, Debug)

///|
pub fn H3ErrorCode::wire_value(self : H3ErrorCode) -> Int64 {
  match self {
    H3NoError => 0x100L
    H3GeneralProtocolError => 0x101L
    H3InternalError => 0x102L
    H3StreamCreationError => 0x103L
    H3ClosedCriticalStream => 0x104L
    H3FrameUnexpected => 0x105L
    H3FrameError => 0x106L
    H3ExcessiveLoad => 0x107L
    H3IdError => 0x108L
    H3SettingsError => 0x109L
    H3MissingSettings => 0x10aL
    H3RequestRejected => 0x10bL
    H3RequestCancelled => 0x10cL
    H3RequestIncomplete => 0x10dL
    H3MessageError => 0x10eL
    H3ConnectError => 0x10fL
    H3VersionFallback => 0x110L
    QpackDecompressionFailed => 0x200L
    QpackEncoderStreamError => 0x201L
    QpackDecoderStreamError => 0x202L
  }
}

///|
pub(all) suberror Http3Error {
  Http3NeedMoreInput
  Http3UnexpectedEof(String)
  Http3ConnectionError(H3ErrorCode, String)
  Http3StreamError(Int64, H3ErrorCode, String)
  Http3LimitExceeded(String, Int)
} derive(Eq, Debug)

///|
pub(all) struct H3Setting {
  id : Int64
  value : Int64
} derive(Eq, Debug)

///|
pub(all) enum Http3Frame {
  H3Data(Bytes)
  H3Headers(Bytes)
  H3CancelPush(Int64)
  H3SettingsFrame(Array[H3Setting])
  H3PushPromise(Int64, Bytes)
  H3Goaway(Int64)
  H3MaxPushId(Int64)
  H3Unknown(Int64, Bytes)
} derive(Eq, Debug)

///|
fn h3_append_bytes(output : Array[Byte], bytes : BytesView) -> Unit {
  for byte in bytes {
    output.push(byte)
  }
}

///|
fn h3_varint(value : Int64) -> Result[Bytes, Http3Error] {
  match @quic.QuicVarInt::new(value) {
    Ok(encoded) => Ok(encoded.encode())
    Err(_) =>
      Err(Http3ConnectionError(H3FrameError, "HTTP/3 integer is out of range"))
  }
}

///|
fn h3_decode_varint(input : BytesView) -> Result[(Int64, Int), Http3Error] {
  match @quic.quic_decode_varint(input) {
    Ok((value, used)) => Ok((value.value(), used))
    Err(NeedMoreInput) => Err(Http3NeedMoreInput)
    Err(NonCanonicalVarInt) =>
      Err(
        Http3ConnectionError(
          H3FrameError,
          "non-canonical HTTP/3 variable-length integer",
        ),
      )
    Err(_) =>
      Err(
        Http3ConnectionError(
          H3FrameError,
          "invalid HTTP/3 variable-length integer",
        ),
      )
  }
}

///|
fn h3_int_length(value : Int64) -> Result[Int, Http3Error] {
  if value < 0L || value > @int.MAX_VALUE.to_int64() {
    return Err(
      Http3ConnectionError(
        H3ExcessiveLoad,
        "frame length exceeds platform limits",
      ),
    )
  }
  Ok(value.to_int())
}

///|
fn h3_single_varint_payload(
  payload : BytesView,
  label : String,
) -> Result[Int64, Http3Error] {
  let (value, used) = match h3_decode_varint(payload) {
    Ok(result) => result
    Err(Http3NeedMoreInput) =>
      return Err(
        Http3ConnectionError(H3FrameError, label + " payload is truncated"),
      )
    Err(error) => return Err(error)
  }
  if used != payload.length() {
    return Err(
      Http3ConnectionError(H3FrameError, label + " payload has trailing bytes"),
    )
  }
  Ok(value)
}

///|
fn h3_decode_settings(
  payload : BytesView,
) -> Result[Array[H3Setting], Http3Error] {
  let settings : Array[H3Setting] = []
  let mut offset = 0
  while offset < payload.length() {
    let (id, id_used) = match h3_decode_varint(payload[offset:]) {
      Ok(result) => result
      Err(Http3NeedMoreInput) =>
        return Err(
          Http3ConnectionError(H3FrameError, "SETTINGS identifier is truncated"),
        )
      Err(error) => return Err(error)
    }
    offset += id_used
    let (value, value_used) = match h3_decode_varint(payload[offset:]) {
      Ok(result) => result
      Err(Http3NeedMoreInput) =>
        return Err(
          Http3ConnectionError(H3FrameError, "SETTINGS value is truncated"),
        )
      Err(error) => return Err(error)
    }
    offset += value_used
    if id == 2L || id == 3L || id == 4L || id == 5L {
      return Err(
        Http3ConnectionError(
          H3SettingsError,
          "HTTP/2 setting identifier is reserved in HTTP/3",
        ),
      )
    }
    for setting in settings {
      if setting.id == id {
        return Err(
          Http3ConnectionError(H3SettingsError, "duplicate HTTP/3 setting"),
        )
      }
    }
    settings.push({ id, value, })
  }
  Ok(settings)
}

///|
fn h3_reserved_http2_frame(typ : Int64) -> Bool {
  typ == 2L || typ == 6L || typ == 8L || typ == 9L
}

///|
fn h3_decode_payload(
  typ : Int64,
  payload : Bytes,
) -> Result[Http3Frame, Http3Error] {
  if typ == H3_FRAME_DATA {
    Ok(H3Data(payload))
  } else if typ == H3_FRAME_HEADERS {
    Ok(H3Headers(payload))
  } else if typ == H3_FRAME_CANCEL_PUSH {
    match h3_single_varint_payload(payload, "CANCEL_PUSH") {
      Ok(value) => Ok(H3CancelPush(value))
      Err(error) => Err(error)
    }
  } else if typ == H3_FRAME_SETTINGS {
    match h3_decode_settings(payload) {
      Ok(value) => Ok(H3SettingsFrame(value))
      Err(error) => Err(error)
    }
  } else if typ == H3_FRAME_PUSH_PROMISE {
    let (push_id, used) = match h3_decode_varint(payload) {
      Ok(result) => result
      Err(Http3NeedMoreInput) =>
        return Err(
          Http3ConnectionError(
            H3FrameError,
            "PUSH_PROMISE push ID is truncated",
          ),
        )
      Err(error) => return Err(error)
    }
    Ok(H3PushPromise(push_id, payload[used:].to_owned()))
  } else if typ == H3_FRAME_GOAWAY {
    match h3_single_varint_payload(payload, "GOAWAY") {
      Ok(value) => Ok(H3Goaway(value))
      Err(error) => Err(error)
    }
  } else if typ == H3_FRAME_MAX_PUSH_ID {
    match h3_single_varint_payload(payload, "MAX_PUSH_ID") {
      Ok(value) => Ok(H3MaxPushId(value))
      Err(error) => Err(error)
    }
  } else if h3_reserved_http2_frame(typ) {
    Err(
      Http3ConnectionError(
        H3FrameUnexpected,
        "reserved HTTP/2 frame type received in HTTP/3",
      ),
    )
  } else {
    Ok(H3Unknown(typ, payload))
  }
}

///|
pub fn decode_http3_frame(
  input : BytesView,
  max_payload_bytes? : Int = 16 * 1024 * 1024,
) -> Result[(Http3Frame, Int), Http3Error] {
  if max_payload_bytes < 0 {
    return Err(Http3LimitExceeded("frame payload", max_payload_bytes))
  }
  let (typ, type_used) = match h3_decode_varint(input) {
    Ok(result) => result
    Err(error) => return Err(error)
  }
  let (length64, length_used) = match h3_decode_varint(input[type_used:]) {
    Ok(result) => result
    Err(error) => return Err(error)
  }
  let length = match h3_int_length(length64) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if length > max_payload_bytes {
    return Err(Http3LimitExceeded("frame payload", max_payload_bytes))
  }
  let header_length = type_used + length_used
  if header_length > input.length() || length > input.length() - header_length {
    return Err(Http3NeedMoreInput)
  }
  let payload = input[header_length:header_length + length].to_owned()
  let frame = match h3_decode_payload(typ, payload) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok((frame, header_length + length))
}

///|
pub fn encode_http3_frame(frame : Http3Frame) -> Result[Bytes, Http3Error] {
  let (typ, payload) = match frame {
    H3Data(value) => (H3_FRAME_DATA, value)
    H3Headers(value) => (H3_FRAME_HEADERS, value)
    H3CancelPush(value) => {
      let payload = match h3_varint(value) {
        Ok(result) => result
        Err(error) => return Err(error)
      }
      (H3_FRAME_CANCEL_PUSH, payload)
    }
    H3SettingsFrame(settings) => {
      let bytes : Array[Byte] = []
      let seen : Array[Int64] = []
      for setting in settings {
        if setting.id == 2L ||
          setting.id == 3L ||
          setting.id == 4L ||
          setting.id == 5L {
          return Err(
            Http3ConnectionError(
              H3SettingsError,
              "reserved HTTP/2 setting identifier",
            ),
          )
        }
        for id in seen {
          if id == setting.id {
            return Err(
              Http3ConnectionError(H3SettingsError, "duplicate HTTP/3 setting"),
            )
          }
        }
        seen.push(setting.id)
        let id = match h3_varint(setting.id) {
          Ok(result) => result
          Err(error) => return Err(error)
        }
        let value = match h3_varint(setting.value) {
          Ok(result) => result
          Err(error) => return Err(error)
        }
        h3_append_bytes(bytes, id)
        h3_append_bytes(bytes, value)
      }
      (H3_FRAME_SETTINGS, Bytes::from_array(bytes))
    }
    H3PushPromise(push_id, section) => {
      let bytes : Array[Byte] = []
      let id = match h3_varint(push_id) {
        Ok(result) => result
        Err(error) => return Err(error)
      }
      h3_append_bytes(bytes, id)
      h3_append_bytes(bytes, section)
      (H3_FRAME_PUSH_PROMISE, Bytes::from_array(bytes))
    }
    H3Goaway(value) => {
      let payload = match h3_varint(value) {
        Ok(result) => result
        Err(error) => return Err(error)
      }
      (H3_FRAME_GOAWAY, payload)
    }
    H3MaxPushId(value) => {
      let payload = match h3_varint(value) {
        Ok(result) => result
        Err(error) => return Err(error)
      }
      (H3_FRAME_MAX_PUSH_ID, payload)
    }
    H3Unknown(value, bytes) => {
      if h3_reserved_http2_frame(value) {
        return Err(
          Http3ConnectionError(
            H3FrameUnexpected,
            "cannot encode a reserved HTTP/2 frame type",
          ),
        )
      }
      (value, bytes)
    }
  }
  let output : Array[Byte] = []
  let encoded_type = match h3_varint(typ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let encoded_length = match h3_varint(payload.length().to_int64()) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  h3_append_bytes(output, encoded_type)
  h3_append_bytes(output, encoded_length)
  h3_append_bytes(output, payload)
  Ok(Bytes::from_array(output))
}

///|
pub struct Http3FrameDecoder {
  mut buffer : Array[Byte]
  max_buffer_bytes : Int
  max_payload_bytes : Int
  mut failure : Http3Error?
}

///|
pub fn Http3FrameDecoder::new(
  max_buffer_bytes? : Int = 256 * 1024,
  max_payload_bytes? : Int = 256 * 1024 - 16,
) -> Result[Http3FrameDecoder, Http3Error] {
  if max_buffer_bytes <= 0 ||
    max_payload_bytes < 0 ||
    max_payload_bytes > max_buffer_bytes {
    return Err(Http3LimitExceeded("frame decoder buffer", max_buffer_bytes))
  }
  Ok({ buffer: [], max_buffer_bytes, max_payload_bytes, failure: None, })
}

///|
pub fn Http3FrameDecoder::feed(
  self : Http3FrameDecoder,
  input : BytesView,
) -> Result[Unit, Http3Error] {
  if self.failure is Some(error) {
    return Err(error)
  }
  if self.buffer.length() > self.max_buffer_bytes ||
    input.length() > self.max_buffer_bytes - self.buffer.length() {
    let error = Http3LimitExceeded(
      "frame decoder buffer",
      self.max_buffer_bytes,
    )
    self.failure = Some(error)
    return Err(error)
  }
  h3_append_bytes(self.buffer, input)
  Ok(())
}

///|
pub fn Http3FrameDecoder::next(
  self : Http3FrameDecoder,
) -> Result[Http3Frame?, Http3Error] {
  if self.failure is Some(error) {
    return Err(error)
  }
  match
    decode_http3_frame(
      Bytes::from_array(self.buffer),
      max_payload_bytes=self.max_payload_bytes,
    ) {
    Err(Http3NeedMoreInput) => Ok(None)
    Err(error) => {
      self.failure = Some(error)
      Err(error)
    }
    Ok((frame, used)) => {
      let remaining : Array[Byte] = []
      for index in used..<self.buffer.length() {
        remaining.push(self.buffer[index])
      }
      self.buffer = remaining
      Ok(Some(frame))
    }
  }
}

///|
pub fn Http3FrameDecoder::finish(
  self : Http3FrameDecoder,
) -> Result[Unit, Http3Error] {
  if self.failure is Some(error) {
    return Err(error)
  }
  if !self.buffer.is_empty() {
    let error = Http3UnexpectedEof("HTTP/3 stream ended inside a frame")
    self.failure = Some(error)
    return Err(error)
  }
  Ok(())
}
