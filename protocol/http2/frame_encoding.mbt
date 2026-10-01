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
  typ : Int,
  flags : Int,
  stream_id : Int,
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
fn encode_window_update_frame(stream_id : Int, increment : Int) -> Array[Byte] {
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
fn h2_error_code_value(code : H2ErrorCode) -> Int {
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
  stream_id : Int,
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
  stream_id : Int,
  fragment : Array[Byte],
  end_stream : Bool,
  max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE,
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
  stream_id : Int,
  payload : Array[Byte],
  end_stream : Bool,
  max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE,
) -> Array[Byte] {
  let out : Array[Byte] = []
  let mut offset = 0
  let mut first = true
  while first || offset < payload.length() {
    let remaining = payload.length() - offset
    let take = remaining.min(max_frame_size)
    let last = offset + take == payload.length()
    append_frame(
      out,
      H2_FRAME_DATA,
      if last && end_stream {
        H2_FLAGS_END_STREAM
      } else {
        0
      },
      stream_id,
      payload[offset:offset + take],
    )
    offset += take
    first = false
  }
  out
}
