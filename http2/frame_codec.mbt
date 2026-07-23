///|
pub struct FrameDecoder {
  buffer : @codec.Buffer
  mut pending : H2FrameHeader?
  max_frame_size : Int
}

///|
pub fn FrameDecoder::new(
  max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE,
  max_buffer_size? : Int = 256 * 1024,
) -> FrameDecoder {
  {
    buffer: @codec.Buffer::new(max_bytes=max_buffer_size),
    pending: None,
    max_frame_size,
  }
}

///|
pub fn FrameDecoder::feed(
  self : FrameDecoder,
  bytes : BytesView,
) -> Result[Unit, H2ProtocolError] {
  match self.buffer.feed(bytes) {
    Ok(_) => Ok(())
    Err(_) =>
      Err(
        ConnectionError(
          EnhanceYourCalm,
          "HTTP/2 connection buffer limit exceeded",
        ),
      )
  }
}

///|
pub fn FrameDecoder::next(
  self : FrameDecoder,
) -> Result[H2Frame?, H2ProtocolError] {
  if self.pending is None {
    if self.buffer.length() < 9 {
      return Ok(None)
    }
    let header = self.buffer.take(9)
    if (header[5].to_int() & 0x80) != 0 {
      return Err(
        ConnectionError(ProtocolError, "reserved stream identifier bit is set"),
      )
    }
    let length = ((header[0].to_int() & 0xff) << 16) |
      ((header[1].to_int() & 0xff) << 8) |
      (header[2].to_int() & 0xff)
    if length > self.max_frame_size {
      return Err(
        ConnectionError(FrameSizeError, "frame exceeds configured maximum"),
      )
    }
    self.pending = Some({
      length,
      typ: header[3].to_int() & 0xff,
      flags: header[4].to_int() & 0xff,
      stream_id: ((header[5].to_int() & 0x7f) << 24) |
      ((header[6].to_int() & 0xff) << 16) |
      ((header[7].to_int() & 0xff) << 8) |
      (header[8].to_int() & 0xff),
    })
  }
  guard self.pending is Some(header) else { return Ok(None) }
  if self.buffer.length() < header.length {
    return Ok(None)
  }
  let payload = self.buffer.take(header.length).to_array()
  self.pending = None
  Ok(Some({ header, payload }))
}

///|
pub fn header_fragment(frame : H2Frame) -> Result[Bytes, H2ProtocolError] {
  if frame.header.typ == H2_FRAME_CONTINUATION {
    return Ok(Bytes::from_array(frame.payload))
  }
  if frame.header.typ != H2_FRAME_HEADERS {
    return Err(
      ConnectionError(ProtocolError, "frame is not HEADERS or CONTINUATION"),
    )
  }
  let mut offset = 0
  let mut padding = 0
  if (frame.header.flags & H2_FLAGS_PADDED) != 0 {
    if frame.payload.is_empty() {
      return Err(
        ConnectionError(ProtocolError, "padded HEADERS has no pad length"),
      )
    }
    padding = frame.payload[0].to_int() & 0xff
    offset = 1
  }
  if (frame.header.flags & H2_FLAGS_PRIORITY) != 0 {
    offset += 5
  }
  if offset + padding > frame.payload.length() {
    return Err(ConnectionError(ProtocolError, "invalid HEADERS padding"))
  }
  Ok(
    Bytes::from_array(frame.payload)[offset:frame.payload.length() - padding].to_owned(),
  )
}

///|
pub fn encode_ping_ack(payload : Array[Byte]) -> Result[Bytes, H2ProtocolError] {
  if payload.length() != 8 {
    return Err(ConnectionError(FrameSizeError, "PING payload must be 8 bytes"))
  }
  Ok(Bytes::from_array(build_ping_frame(payload, true)))
}

///|
pub fn encode_window_update(
  stream_id : Int,
  increment : Int,
) -> Result[Bytes, H2ProtocolError] {
  if increment <= 0 || increment > 0x7fffffff {
    return Err(
      ConnectionError(ProtocolError, "invalid WINDOW_UPDATE increment"),
    )
  }
  Ok(Bytes::from_array(encode_window_update_frame(stream_id, increment)))
}

///|
pub fn encode_response_frames(
  context : HpackContext,
  stream_id : Int,
  response : @types.Response[Bytes],
  max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE,
) -> Result[Bytes, H2ProtocolError] {
  let headers = match
    encode_response_headers(
      context,
      stream_id,
      response,
      response.body.is_empty(),
      max_frame_size~,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let out : Array[Byte] = []
  for byte in headers {
    out.push(byte)
  }
  if !response.body.is_empty() {
    let data = match
      encode_data_frames(stream_id, response.body, true, max_frame_size~) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    for byte in data {
      out.push(byte)
    }
  }
  Ok(Bytes::from_array(out))
}

///|
pub fn encode_response_headers(
  context : HpackContext,
  stream_id : Int,
  response : @types.Response[Bytes],
  end_stream : Bool,
  max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE,
) -> Result[Bytes, H2ProtocolError] {
  if max_frame_size < 1 {
    return Err(
      ConnectionError(FrameSizeError, "max frame size must be positive"),
    )
  }
  let fields : Array[HpackHeader] = [
    { name: ":status", value: response.status.to_string() },
  ]
  for field in response.headers.fields() {
    let name = field.name.value
    if name == "connection" ||
      name == "transfer-encoding" ||
      name == "upgrade" ||
      name == "keep-alive" {
      continue
    }
    fields.push({ name, value: field.value.to_string_lossy() })
  }
  let block = match context.encode_incremental(fields) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok(
    Bytes::from_array(
      build_headers_frames(
        stream_id,
        block.to_array(),
        end_stream,
        max_frame_size~,
      ),
    ),
  )
}

///|
pub fn encode_data_frames(
  stream_id : Int,
  body : Bytes,
  end_stream : Bool,
  max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE,
) -> Result[Bytes, H2ProtocolError] {
  if max_frame_size < 1 {
    return Err(
      ConnectionError(FrameSizeError, "max frame size must be positive"),
    )
  }
  Ok(
    Bytes::from_array(
      build_data_frames(stream_id, body.to_array(), end_stream, max_frame_size~),
    ),
  )
}

///|
fn method_text(http_method : @types.Method) -> String {
  match http_method {
    Get => "GET"
    Post => "POST"
    Put => "PUT"
    Delete => "DELETE"
    Head => "HEAD"
    Options => "OPTIONS"
    Patch => "PATCH"
    Trace => "TRACE"
    Connect => "CONNECT"
    Extension(value) => value
  }
}

///|
pub fn encode_request_frames(
  context : HpackContext,
  stream_id : Int,
  request : @types.Request[Bytes],
  scheme? : String = "http",
  max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE,
) -> Result[Bytes, H2ProtocolError] {
  if max_frame_size < 1 {
    return Err(
      ConnectionError(FrameSizeError, "max frame size must be positive"),
    )
  }
  let authority = request.headers
    .get_string("host")
    .map(fn(value) { value.to_string_lossy() })
    .unwrap_or("")
  let fields : Array[HpackHeader] = [
    { name: ":method", value: method_text(request.http_method) },
    { name: ":scheme", value: scheme },
    { name: ":authority", value: authority },
    { name: ":path", value: request.uri.value },
  ]
  for field in request.headers.fields() {
    let name = field.name.value
    if name == "host" ||
      name == "connection" ||
      name == "transfer-encoding" ||
      name == "upgrade" ||
      name == "keep-alive" {
      continue
    }
    fields.push({ name, value: field.value.to_string_lossy() })
  }
  let block = match context.encode_incremental(fields) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let headers = build_headers_frames(
    stream_id,
    block.to_array(),
    request.body.is_empty(),
    max_frame_size~,
  )
  let out : Array[Byte] = []
  for byte in headers {
    out.push(byte)
  }
  if !request.body.is_empty() {
    for
      byte in build_data_frames(
        stream_id,
        request.body.to_array(),
        true,
        max_frame_size~,
      ) {
      out.push(byte)
    }
  }
  Ok(Bytes::from_array(out))
}
