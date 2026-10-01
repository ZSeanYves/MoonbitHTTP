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
fn ascii_equal_fold(value : BytesView, expected : BytesView) -> Bool {
  if value.length() != expected.length() {
    return false
  }
  for index in 0..<value.length() {
    let byte = value[index]
    let folded = if byte >= b'A' && byte <= b'Z' {
      (byte.to_int() + 32).to_byte()
    } else {
      byte
    }
    if folded != expected[index] {
      return false
    }
  }
  true
}

///|
fn connection_specific_header(name : String) -> Bool {
  name == "connection" ||
  name == "proxy-connection" ||
  name == "transfer-encoding" ||
  name == "upgrade" ||
  name == "keep-alive"
}

///|
fn validate_regular_field(
  stream_id : Int,
  field : @types.HeaderField,
  trailer : Bool,
) -> Result[Unit, H2ProtocolError] {
  if @types.HeaderName::parse(field.name.value) != Ok(field.name) ||
    @types.HeaderValue::from_bytes(field.value.bytes) != Ok(field.value) {
    return Err(StreamError(stream_id, ProtocolError, "invalid HTTP/2 field"))
  }
  let name = field.name.value
  if connection_specific_header(name) ||
    (name == "te" && !ascii_equal_fold(field.value.bytes, b"trailers")) ||
    (
      trailer &&
      (
        name == "content-length" ||
        name == "host" ||
        name == "te" ||
        name == "trailer"
      )
    ) {
    return Err(StreamError(stream_id, ProtocolError, "forbidden HTTP/2 field"))
  }
  Ok(())
}

///|
fn authority_matches(left : @types.Authority, right : @types.Authority) -> Bool {
  left.host == right.host &&
  left.port == right.port &&
  left.ip_literal == right.ip_literal
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
  if request.http_method.validate() is Err(_) ||
    request.uri.validate_request_target(request.http_method) is Err(_) {
    return Err(StreamError(stream_id, ProtocolError, "invalid request target"))
  }
  let host_values = request.headers.get_all_string("host")
  if host_values.length() > 1 {
    return Err(StreamError(stream_id, ProtocolError, "multiple Host fields"))
  }
  let host_authority : @types.Authority? = if host_values.is_empty() {
    None
  } else {
    let text = @utf8.decode(host_values[0].bytes) catch {
      _ =>
        return Err(StreamError(stream_id, ProtocolError, "invalid Host field"))
    }
    match @types.Authority::parse_endpoint(text) {
      Ok(value) => Some(value)
      Err(_) =>
        return Err(StreamError(stream_id, ProtocolError, "invalid Host field"))
    }
  }
  let target_authority = request.uri.authority
  if target_authority is Some(left) &&
    host_authority is Some(right) &&
    !authority_matches(left, right) {
    return Err(StreamError(stream_id, ProtocolError, "authority mismatch"))
  }
  let authority = match target_authority {
    Some(value) => value
    None =>
      match host_authority {
        Some(value) => value
        None =>
          return Err(
            StreamError(
              stream_id,
              ProtocolError,
              "request authority is missing",
            ),
          )
      }
  }
  let fields : Array[HpackHeader] = [
    { name: ":method", value: @utf8.encode(method_text(request.http_method)), },
  ]
  if request.http_method == Connect {
    fields.push({ name: ":authority", value: @utf8.encode(authority.value), })
  } else {
    let scheme = request.uri.scheme.unwrap_or(requested_scheme).to_lower()
    if (scheme != "http" && scheme != "https") ||
      (request.uri.scheme is Some(value) && value != scheme) {
      return Err(
        StreamError(stream_id, ProtocolError, "invalid request scheme"),
      )
    }
    let path = match request.uri.form {
      AsteriskForm => "*"
      OriginForm | AbsoluteForm =>
        match request.uri.origin_form() {
          Ok(value) => value
          Err(_) =>
            return Err(
              StreamError(stream_id, ProtocolError, "invalid request path"),
            )
        }
      AuthorityForm =>
        return Err(
          StreamError(stream_id, ProtocolError, "invalid request path"),
        )
    }
    fields.push({ name: ":scheme", value: @utf8.encode(scheme), })
    fields.push({ name: ":authority", value: @utf8.encode(authority.value), })
    fields.push({ name: ":path", value: @utf8.encode(path), })
  }
  for field in request.headers.fields() {
    if field.name.value == "host" {
      continue
    }
    match validate_regular_field(stream_id, field, false) {
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
    match validate_regular_field(stream_id, field, false) {
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
    match validate_regular_field(stream_id, field, true) {
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
fn method_text(http_method : @types.Method) -> String {
  http_method.as_str()
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
