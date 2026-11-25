///|
fn encode_frame_header(header : H2FrameHeader) -> Array[Byte] {
  let length = header.length
  let stream_id = header.stream_id & 0x7fffffff
  [
    ((length >> 16) & 0xff).to_byte(),
    ((length >> 8) & 0xff).to_byte(),
    (length & 0xff).to_byte(),
    (header.typ & 0xff).to_byte(),
    (header.flags & 0xff).to_byte(),
    ((stream_id >> 24) & 0x7f).to_byte(),
    ((stream_id >> 16) & 0xff).to_byte(),
    ((stream_id >> 8) & 0xff).to_byte(),
    (stream_id & 0xff).to_byte(),
  ]
}

///|
fn append_frame(
  out : Array[Byte],
  typ : Int32,
  flags : Int32,
  stream_id : Int32,
  payload : ArrayView[Byte],
) -> Unit {
  let encoded = encode_frame_header({
    length: payload.length(),
    typ,
    flags,
    stream_id,
  })
  for byte in encoded {
    out.push(byte)
  }
  for byte in payload {
    out.push(byte)
  }
}

///|
pub fn encode_settings_frame(
  settings : Array[H2Setting],
  ack : Bool,
) -> Array[Byte] {
  let payload : Array[Byte] = []
  if !ack {
    for setting in settings {
      let id = setting.id & 0xffff
      let value = setting.value
      payload.push(((id >> 8) & 0xff).to_byte())
      payload.push((id & 0xff).to_byte())
      payload.push(((value >> 24) & 0xff).to_byte())
      payload.push(((value >> 16) & 0xff).to_byte())
      payload.push(((value >> 8) & 0xff).to_byte())
      payload.push((value & 0xff).to_byte())
    }
  }
  let out : Array[Byte] = []
  append_frame(
    out,
    H2_FRAME_SETTINGS,
    if ack {
      H2_FLAGS_ACK
    } else {
      0
    },
    0,
    payload,
  )
  out
}

///|
fn build_ping_frame(payload : Array[Byte], ack : Bool) -> Array[Byte] {
  let out : Array[Byte] = []
  append_frame(
    out,
    H2_FRAME_PING,
    if ack {
      H2_FLAGS_ACK
    } else {
      0
    },
    0,
    payload,
  )
  out
}

///|
fn encode_window_update_frame(
  stream_id : Int32,
  increment : Int32,
) -> Array[Byte] {
  let value = increment & 0x7fffffff
  let payload : Array[Byte] = [
    ((value >> 24) & 0x7f).to_byte(),
    ((value >> 16) & 0xff).to_byte(),
    ((value >> 8) & 0xff).to_byte(),
    (value & 0xff).to_byte(),
  ]
  let out : Array[Byte] = []
  append_frame(out, H2_FRAME_WINDOW_UPDATE, 0, stream_id, payload)
  out
}

///|
fn h2_error_code_value(code : H2ErrorCode) -> Int32 {
  match code {
    NoError => 0
    ProtocolError => 1
    InternalError => 2
    FlowControlError => 3
    SettingsTimeout => 4
    StreamClosed => 5
    FrameSizeError => 6
    RefusedStream => 7
    Cancel => 8
    CompressionError => 9
    ConnectError => 10
    EnhanceYourCalm => 11
    InadequateSecurity => 12
    Http11Required => 13
  }
}

///|
pub fn encode_rst_stream(
  stream_id : Int32,
  code : H2ErrorCode,
) -> Result[Bytes, H2ProtocolError] {
  if stream_id <= 0 || stream_id > 0x7fffffff {
    return Err(ConnectionError(ProtocolError, "invalid RST_STREAM id"))
  }
  let value = h2_error_code_value(code)
  let payload : Array[Byte] = [
    ((value >> 24) & 0xff).to_byte(),
    ((value >> 16) & 0xff).to_byte(),
    ((value >> 8) & 0xff).to_byte(),
    (value & 0xff).to_byte(),
  ]
  let out : Array[Byte] = []
  append_frame(out, H2_FRAME_RST_STREAM, 0, stream_id, payload)
  Ok(Bytes::from_array(out))
}

///|
fn build_headers_frames(
  stream_id : Int32,
  fragment : Array[Byte],
  end_stream : Bool,
  max_frame_size~ : Int32 = H2_DEFAULT_MAX_FRAME_SIZE,
) -> Array[Byte] {
  let out : Array[Byte] = []
  let mut offset = 0
  let mut first = true
  while first || offset < fragment.length() {
    let remaining = fragment.length() - offset
    let take = remaining.min(max_frame_size)
    let last = offset + take == fragment.length()
    let typ = if first { H2_FRAME_HEADERS } else { H2_FRAME_CONTINUATION }
    let mut flags = if last { H2_FLAGS_END_HEADERS } else { 0 }
    if first && end_stream {
      flags = flags | H2_FLAGS_END_STREAM
    }
    append_frame(out, typ, flags, stream_id, fragment[offset:offset + take])
    offset += take
    first = false
  }
  out
}

///|
fn build_data_frames(
  stream_id : Int32,
  payload : BytesView,
  end_stream : Bool,
  max_frame_size~ : Int32,
  prefix~ : BytesView = b"",
) -> Result[Bytes, H2ProtocolError] {
  let frames = if payload.is_empty() {
    1
  } else {
    1 + (payload.length() - 1) / max_frame_size
  }
  let room = 0x7fffffff - prefix.length() - payload.length()
  if frames > room / 9 || room < 0 {
    return Err(
      ConnectionError(FrameSizeError, "encoded DATA exceeds buffer size"),
    )
  }
  let out = FixedArray::make(
    prefix.length() + payload.length() + 9 * frames,
    b'\x00',
  )
  out.blit_from_bytesview(0, prefix)
  let mut pos = prefix.length()
  let mut offset = 0
  for _ in 0..<frames {
    let take = (payload.length() - offset).min(max_frame_size)
    let header = encode_frame_header({
      length: take,
      typ: H2_FRAME_DATA,
      flags: if offset + take == payload.length() && end_stream {
        H2_FLAGS_END_STREAM
      } else {
        0
      },
      stream_id,
    })
    for i, byte in header {
      out[pos + i] = byte
    }
    out.blit_from_bytesview(pos + 9, payload[offset:offset + take])
    offset += take
    pos += 9 + take
  }
  Ok(out.unsafe_reinterpret_as_bytes())
}

///|
/// Encode GOAWAY without optional diagnostic data.
pub fn encode_goaway(
  last_stream_id : Int32,
  code : H2ErrorCode,
) -> Result[Bytes, H2ProtocolError] {
  if last_stream_id < 0 {
    return Err(ConnectionError(ProtocolError, "invalid GOAWAY stream id"))
  }
  let payload : Array[Byte] = []
  for value in [last_stream_id, h2_error_code_value(code)] {
    for shift in [24, 16, 8, 0] {
      payload.push((value >> shift).to_byte())
    }
  }
  let frame = []
  append_frame(frame, H2_FRAME_GOAWAY, 0, 0, payload)
  Ok(Bytes::from_array(frame))
}
