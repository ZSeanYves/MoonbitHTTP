///|
pub struct FrameDecoder {
  buffer : @codec.Buffer
  mut pending : H2FrameHeader?
  max_frame_size : Int
  mut failure : H2ProtocolError?
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
    failure: None,
  }
}

///|
pub fn FrameDecoder::feed(
  self : FrameDecoder,
  bytes : BytesView,
) -> Result[Unit, H2ProtocolError] {
  if self.failure is Some(error) {
    return Err(error)
  }
  match self.buffer.feed(bytes) {
    Ok(_) => Ok(())
    Err(_) => {
      let error = ConnectionError(
        EnhanceYourCalm,
        "HTTP/2 connection buffer limit exceeded",
      )
      self.failure = Some(error)
      Err(error)
    }
  }
}

///|
fn FrameDecoder::next_impl(
  self : FrameDecoder,
) -> Result[H2Frame?, H2ProtocolError] {
  if self.pending is None {
    if self.buffer.length() < 9 {
      return Ok(None)
    }
    let header = self.buffer.take(9)
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
  Ok(Some({ header, payload, }))
}

///|
pub fn FrameDecoder::next(
  self : FrameDecoder,
) -> Result[H2Frame?, H2ProtocolError] {
  if self.failure is Some(error) {
    return Err(error)
  }
  match self.next_impl() {
    Err(error) => {
      self.failure = Some(error)
      Err(error)
    }
    value => value
  }
}

///|
pub fn header_fragment(frame : H2Frame) -> Result[Bytes, H2ProtocolError] {
  if frame.header.length != frame.payload.length() || frame.header.length < 0 {
    return Err(ConnectionError(FrameSizeError, "frame payload length mismatch"))
  }
  match h2_header_fragment_bounds(frame) {
    Ok((start, end)) => Ok(Bytes::from_array(frame.payload[start:end]))
    Err(error) => Err(error)
  }
}

///|
fn h2_header_fragment_bounds(
  frame : H2Frame,
) -> Result[(Int, Int), H2ProtocolError] {
  let end = frame.payload.length()
  if frame.header.typ == H2_FRAME_CONTINUATION {
    return Ok((0, end))
  }
  if frame.header.typ != H2_FRAME_HEADERS {
    return Err(
      ConnectionError(ProtocolError, "frame is not HEADERS or CONTINUATION"),
    )
  }
  let mut start = 0
  let mut padding = 0
  if (frame.header.flags & H2_FLAGS_PADDED) != 0 {
    if end == 0 {
      return Err(ConnectionError(FrameSizeError, "missing HEADERS pad length"))
    }
    padding = frame.payload[0].to_int()
    start = 1
  }
  if (frame.header.flags & H2_FLAGS_PRIORITY) != 0 {
    if end < start + 5 {
      return Err(ConnectionError(FrameSizeError, "truncated HEADERS priority"))
    }
    if u31(frame.payload, start) == frame.header.stream_id {
      return Err(ConnectionError(ProtocolError, "HEADERS depends on itself"))
    }
    start += 5
  }
  if start + padding > end {
    return Err(ConnectionError(ProtocolError, "invalid HEADERS padding"))
  }
  Ok((start, end - padding))
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
  if stream_id < 0 || stream_id > 0x7fffffff {
    return Err(
      ConnectionError(ProtocolError, "invalid WINDOW_UPDATE stream id"),
    )
  }
  if increment <= 0 || increment > 0x7fffffff {
    return Err(
      ConnectionError(ProtocolError, "invalid WINDOW_UPDATE increment"),
    )
  }
  Ok(Bytes::from_array(encode_window_update_frame(stream_id, increment)))
}

///|
fn validate_regular_field(
  stream_id : Int,
  field : @types.HeaderField,
  section : @http_fields.Section,
) -> Result[Unit, H2ProtocolError] {
  // HeaderMap contains validated HeaderName and HeaderValue instances.
  if section.allows(field.name.value, field.value.bytes) {
    Ok(())
  } else {
    Err(StreamError(stream_id, ProtocolError, "forbidden HTTP/2 field"))
  }
}

///|
fn[A] request_hpack_fields(
  stream_id : Int,
  request : @types.Request[A],
  requested_scheme : String,
) -> Result[Array[HpackHeader], H2ProtocolError] {
  if request.version != Http2 {
    return Err(
      StreamError(stream_id, ProtocolError, "request version is not HTTP/2"),
    )
  }
  let target = match @http_fields.request_target(request, requested_scheme) {
    Ok(target) => target
    Err(reason) => return Err(StreamError(stream_id, ProtocolError, reason))
  }
  let fields : Array[HpackHeader] = target.pseudo_fields(request.http_method, (
    name,
    value,
  ) => { name, value, })
  for field in request.headers.fields() {
    if field.name.value == "host" {
      continue
    }
    match validate_regular_field(stream_id, field, Request) {
      Ok(_) =>
        fields.push({ name: field.name.value, value: field.value.bytes, })
      Err(error) => return Err(error)
    }
  }
  Ok(fields)
}

///|
pub fn encode_response_frames(
  context : HpackContext,
  stream_id : Int,
  response : @types.Response[Bytes],
  max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE,
) -> Result[Bytes, H2ProtocolError] {
  if stream_id <= 0 ||
    stream_id > 0x7fffffff ||
    max_frame_size < 1 ||
    max_frame_size > 0xffffff {
    return Err(ConnectionError(FrameSizeError, "invalid HTTP/2 frame size"))
  }
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
pub fn[A] encode_response_headers(
  context : HpackContext,
  stream_id : Int,
  response : @types.Response[A],
  end_stream : Bool,
  max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE,
) -> Result[Bytes, H2ProtocolError] {
  if stream_id <= 0 ||
    stream_id > 0x7fffffff ||
    max_frame_size < 1 ||
    max_frame_size > 0xffffff {
    return Err(
      ConnectionError(FrameSizeError, "max frame size must be positive"),
    )
  }
  if response.version != Http2 || response.status < 100 || response.status > 999 {
    return Err(StreamError(stream_id, ProtocolError, "invalid HTTP/2 response"))
  }
  let fields : Array[HpackHeader] = [
    { name: ":status", value: @utf8.encode(response.status.to_string()), },
  ]
  for field in response.headers.fields() {
    match validate_regular_field(stream_id, field, Response) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    fields.push({ name: field.name.value, value: field.value.bytes, })
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
/// Encodes HTTP/2 trailing headers and closes the stream.
pub fn encode_trailers(
  context : HpackContext,
  stream_id : Int,
  trailers : @types.HeaderMap,
  max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE,
) -> Result[Bytes, H2ProtocolError] {
  if stream_id <= 0 ||
    stream_id > 0x7fffffff ||
    max_frame_size < 1 ||
    max_frame_size > 0xffffff {
    return Err(
      ConnectionError(FrameSizeError, "max frame size must be positive"),
    )
  }
  let fields : Array[HpackHeader] = []
  for field in trailers.fields() {
    match validate_regular_field(stream_id, field, Trailers) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    fields.push({ name: field.name.value, value: field.value.bytes, })
  }
  let block = match context.encode_incremental(fields) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok(
    Bytes::from_array(
      build_headers_frames(stream_id, block.to_array(), true, max_frame_size~),
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
  if stream_id <= 0 ||
    stream_id > 0x7fffffff ||
    max_frame_size < 1 ||
    max_frame_size > 0xffffff {
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
pub fn encode_request_frames(
  context : HpackContext,
  stream_id : Int,
  request : @types.Request[Bytes],
  scheme? : String = "http",
  max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE,
) -> Result[Bytes, H2ProtocolError] {
  if stream_id <= 0 ||
    stream_id > 0x7fffffff ||
    max_frame_size < 1 ||
    max_frame_size > 0xffffff {
    return Err(
      ConnectionError(FrameSizeError, "max frame size must be positive"),
    )
  }
  let fields = match request_hpack_fields(stream_id, request, scheme) {
    Ok(value) => value
    Err(error) => return Err(error)
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

///|
/// Encodes only the request HEADERS block. The body is sent separately by a
/// connection implementation so it can honor flow-control windows.
pub fn[A] encode_request_headers(
  context : HpackContext,
  stream_id : Int,
  request : @types.Request[A],
  end_stream : Bool,
  scheme? : String = "http",
  max_frame_size? : Int = H2_DEFAULT_MAX_FRAME_SIZE,
) -> Result[Bytes, H2ProtocolError] {
  if stream_id <= 0 ||
    stream_id > 0x7fffffff ||
    max_frame_size < 1 ||
    max_frame_size > 0xffffff {
    return Err(
      ConnectionError(FrameSizeError, "max frame size must be positive"),
    )
  }
  let fields = match request_hpack_fields(stream_id, request, scheme) {
    Ok(value) => value
    Err(error) => return Err(error)
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
