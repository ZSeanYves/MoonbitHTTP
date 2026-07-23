///|
pub(all) suberror Http1Error {
  InvalidStartLine(String)
  InvalidHeader(String)
  InvalidFraming(String)
  LimitExceeded(String)
  UnexpectedEof(String)
} derive(Debug, Eq)

///|
pub(all) enum BodyFraming {
  NoBody
  ContentLength(Int)
  Chunked
  CloseDelimited
} derive(Debug, Eq)

///|
pub(all) enum RequestEvent {
  RequestHead(@types.Request[Unit])
  RequestData(Bytes)
  RequestTrailers(@types.HeaderMap)
  RequestEnd
}

///|
pub(all) enum ResponseEvent {
  ResponseHead(@types.Response[Unit])
  ResponseData(Bytes)
  ResponseTrailers(@types.HeaderMap)
  ResponseEnd
}

///|
pub enum BodyState {
  BodyNone
  BodyFixed(Int)
  BodyChunkSize
  BodyChunkData(Int)
  BodyChunkCrlf
  BodyTrailers(@types.HeaderMap, Int, Int)
  BodyClose
  BodyEnd
}

///|
pub struct BodyDecoder {
  mut state : BodyState
  mut total : Int
  limits : @types.Limits
  mut eof : Bool
}

///|
priv enum BodyEvent {
  Data(Bytes)
  Trailers(@types.HeaderMap)
  End
}

///|
fn BodyDecoder::new(
  framing : BodyFraming,
  limits : @types.Limits,
) -> BodyDecoder {
  let state = match framing {
    NoBody => BodyEnd
    ContentLength(0) => BodyEnd
    ContentLength(size) => BodyFixed(size)
    Chunked => BodyChunkSize
    CloseDelimited => BodyClose
  }
  { state, total: 0, limits, eof: false }
}

///|
fn BodyDecoder::finish_input(self : BodyDecoder) -> Unit {
  self.eof = true
}

///|
fn parse_hex_size(line : Bytes) -> Result[Int, Http1Error] {
  let mut size = 0
  let mut digits = 0
  for byte in line {
    if byte == b';' {
      break
    }
    let value = if byte >= b'0' && byte <= b'9' {
      byte.to_int() - 48
    } else if byte >= b'a' && byte <= b'f' {
      byte.to_int() - 87
    } else if byte >= b'A' && byte <= b'F' {
      byte.to_int() - 55
    } else {
      return Err(InvalidFraming("invalid chunk size"))
    }
    digits += 1
    if size > (0x7fffffff - value) / 16 {
      return Err(InvalidFraming("chunk size overflow"))
    }
    size = size * 16 + value
  }
  if digits == 0 {
    Err(InvalidFraming("empty chunk size"))
  } else {
    Ok(size)
  }
}

///|
fn decode_header_line(
  line : Bytes,
  headers : @types.HeaderMap,
) -> Result[Unit, Http1Error] {
  let mut colon = -1
  for i in 0..<line.length() {
    if line[i] == b':' {
      colon = i
      break
    }
  }
  if colon <= 0 {
    return Err(InvalidHeader("header field has no valid name"))
  }
  let name_bytes = line[:colon].to_owned()
  let mut start = colon + 1
  let mut end = line.length()
  while start < end && (line[start] == b' ' || line[start] == b'\t') {
    start += 1
  }
  while end > start && (line[end - 1] == b' ' || line[end - 1] == b'\t') {
    end -= 1
  }
  let name_string = @utf8.decode(name_bytes) catch {
    _ => return Err(InvalidHeader("header name is not ASCII"))
  }
  let name = match @types.HeaderName::parse(name_string) {
    Ok(value) => value
    Err(_) => return Err(InvalidHeader("invalid header name"))
  }
  let value = match @types.HeaderValue::from_bytes(line[start:end].to_owned()) {
    Ok(value) => value
    Err(_) => return Err(InvalidHeader("invalid header value"))
  }
  headers.append(name, value)
  Ok(())
}

///|
fn BodyDecoder::next(
  self : BodyDecoder,
  buffer : @codec.Buffer,
) -> Result[BodyEvent?, Http1Error] {
  match self.state {
    BodyNone => Ok(None)
    BodyEnd => {
      self.state = BodyNone
      Ok(Some(End))
    }
    BodyFixed(remaining) => {
      if remaining == 0 {
        self.state = BodyEnd
        return self.next(buffer)
      }
      if buffer.length() == 0 {
        if self.eof {
          return Err(UnexpectedEof("fixed-length body"))
        }
        return Ok(None)
      }
      let count = if buffer.length() < remaining {
        buffer.length()
      } else {
        remaining
      }
      let data = buffer.take(count)
      self.total += count
      self.state = if count == remaining {
        BodyEnd
      } else {
        BodyFixed(remaining - count)
      }
      Ok(Some(Data(data)))
    }
    BodyChunkSize => {
      let line = match buffer.read_line(self.limits.max_header_line) {
        Ok(line) => line
        Err(NeedMore) => {
          if self.eof {
            return Err(UnexpectedEof("chunk size"))
          }
          return Ok(None)
        }
        Err(_) => return Err(LimitExceeded("chunk size line"))
      }
      let size = match parse_hex_size(line) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if self.total + size > self.limits.max_body_bytes {
        return Err(LimitExceeded("message body"))
      }
      self.state = if size == 0 {
        BodyTrailers(@types.HeaderMap::new(), 0, 0)
      } else {
        BodyChunkData(size)
      }
      self.next(buffer)
    }
    BodyChunkData(remaining) => {
      if buffer.length() == 0 {
        if self.eof {
          return Err(UnexpectedEof("chunk data"))
        }
        return Ok(None)
      }
      let count = if buffer.length() < remaining {
        buffer.length()
      } else {
        remaining
      }
      let data = buffer.take(count)
      self.total += count
      self.state = if count == remaining {
        BodyChunkCrlf
      } else {
        BodyChunkData(remaining - count)
      }
      Ok(Some(Data(data)))
    }
    BodyChunkCrlf => {
      if buffer.length() < 2 {
        if self.eof {
          return Err(UnexpectedEof("chunk terminator"))
        }
        return Ok(None)
      }
      if buffer.take(2) != b"\r\n" {
        return Err(InvalidFraming("chunk data is not followed by CRLF"))
      }
      self.state = BodyChunkSize
      self.next(buffer)
    }
    BodyTrailers(headers, count, bytes) => {
      let line = match buffer.read_line(self.limits.max_header_line) {
        Ok(line) => line
        Err(NeedMore) => {
          if self.eof {
            return Err(UnexpectedEof("chunk trailers"))
          }
          return Ok(None)
        }
        Err(_) => return Err(LimitExceeded("trailer line"))
      }
      if line.is_empty() {
        self.state = BodyEnd
        if headers.is_empty() {
          self.next(buffer)
        } else {
          Ok(Some(Trailers(headers)))
        }
      } else {
        if count + 1 > self.limits.max_header_count ||
          bytes + line.length() + 2 > self.limits.max_header_bytes {
          return Err(LimitExceeded("trailers"))
        }
        match decode_header_line(line, headers) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
        self.state = BodyTrailers(headers, count + 1, bytes + line.length() + 2)
        self.next(buffer)
      }
    }
    BodyClose => {
      if buffer.length() > 0 {
        let data = buffer.take(buffer.length())
        self.total += data.length()
        if self.total > self.limits.max_body_bytes {
          return Err(LimitExceeded("close-delimited body"))
        }
        return Ok(Some(Data(data)))
      }
      if self.eof {
        self.state = BodyEnd
        self.next(buffer)
      } else {
        Ok(None)
      }
    }
  }
}

///|
pub enum RequestState {
  RequestStart
  RequestHeaders(
    @types.Method,
    @types.Uri,
    @types.Version,
    @types.HeaderMap,
    Int,
    Int
  )
  RequestBody(BodyDecoder)
}

///|
pub struct RequestDecoder {
  buffer : @codec.Buffer
  mut state : RequestState
  limits : @types.Limits
  mut eof : Bool
}

///|
pub fn RequestDecoder::new(
  limits? : @types.Limits = @types.Limits::defaults(),
) -> RequestDecoder {
  {
    buffer: @codec.Buffer::new(max_bytes=limits.max_buffer_bytes),
    state: RequestStart,
    limits,
    eof: false,
  }
}

///|
pub fn RequestDecoder::feed(
  self : RequestDecoder,
  bytes : BytesView,
) -> Result[Unit, Http1Error] {
  match self.buffer.feed(bytes) {
    Ok(_) => Ok(())
    Err(_) => Err(LimitExceeded("connection buffer"))
  }
}

///|
pub fn RequestDecoder::finish_input(self : RequestDecoder) -> Unit {
  self.eof = true
  match self.state {
    RequestBody(body) => body.finish_input()
    _ => ()
  }
}

///|
/// Returns bytes read past `RequestEnd`; only use this when changing protocols.
pub fn RequestDecoder::take_buffered(self : RequestDecoder) -> Bytes {
  self.buffer.take(self.buffer.length())
}

///|
fn split_start_line(line : Bytes) -> Result[(Bytes, Bytes, Bytes), Http1Error] {
  let mut first = -1
  let mut second = -1
  for i in 0..<line.length() {
    if line[i] == b' ' {
      if first < 0 {
        first = i
      } else if second < 0 {
        second = i
      } else {
        return Err(InvalidStartLine("too many separators"))
      }
    }
  }
  if first <= 0 || second <= first + 1 || second + 1 >= line.length() {
    return Err(InvalidStartLine("expected three non-empty components"))
  }
  Ok(
    (
      line[:first].to_owned(),
      line[first + 1:second].to_owned(),
      line[second + 1:].to_owned(),
    ),
  )
}

///|
fn parse_method(bytes : Bytes) -> Result[@types.Method, Http1Error] {
  let value = @utf8.decode(bytes) catch {
    _ => return Err(InvalidStartLine("method is not ASCII"))
  }
  let name = match @types.HeaderName::parse(value) {
    Ok(name) => name.value
    Err(_) => return Err(InvalidStartLine("invalid method token"))
  }
  Ok(
    match name {
      "get" => Get
      "post" => Post
      "put" => Put
      "delete" => Delete
      "head" => Head
      "options" => Options
      "patch" => Patch
      "trace" => Trace
      "connect" => Connect
      _ => Extension(value)
    },
  )
}

///|
fn parse_version(bytes : Bytes) -> Result[@types.Version, Http1Error] {
  match bytes {
    b"HTTP/1.0" => Ok(Http10)
    b"HTTP/1.1" => Ok(Http11)
    _ => Err(InvalidStartLine("unsupported HTTP version"))
  }
}

///|
fn parse_request_line(
  line : Bytes,
) -> Result[(@types.Method, @types.Uri, @types.Version), Http1Error] {
  let (method_bytes, target, version) = match split_start_line(line) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let http_method = match parse_method(method_bytes) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let target = @utf8.decode(target) catch {
    _ => return Err(InvalidStartLine("request target is not UTF-8"))
  }
  let uri = match @types.Uri::parse(target) {
    Ok(value) => value
    Err(_) => return Err(InvalidStartLine("invalid request target"))
  }
  let version = match parse_version(version) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok((http_method, uri, version))
}

///|
fn trim_ascii(value : String) -> String {
  let bytes = @utf8.encode(value)
  let mut start = 0
  let mut end = bytes.length()
  while start < end && (bytes[start] == b' ' || bytes[start] == b'\t') {
    start += 1
  }
  while end > start && (bytes[end - 1] == b' ' || bytes[end - 1] == b'\t') {
    end -= 1
  }
  @utf8.decode(bytes[start:end]) catch {
    _ => ""
  }
}

///|
fn comma_values(values : Array[@types.HeaderValue]) -> Array[String] {
  let out : Array[String] = []
  for value in values {
    for part in value.to_string_lossy().split(",") {
      out.push(trim_ascii(part.to_owned()))
    }
  }
  out
}

///|
fn parse_content_length_value(value : String) -> Result[Int, Http1Error] {
  let bytes = @utf8.encode(value)
  if bytes.is_empty() {
    return Err(InvalidFraming("invalid content-length"))
  }
  let mut result = 0
  for byte in bytes {
    if byte < b'0' || byte > b'9' {
      return Err(InvalidFraming("invalid content-length"))
    }
    let digit = byte.to_int() - b'0'.to_int()
    if result > (0x7fffffff - digit) / 10 {
      return Err(InvalidFraming("content-length overflow"))
    }
    result = result * 10 + digit
  }
  Ok(result)
}

///|
fn determine_request_framing(
  headers : @types.HeaderMap,
) -> Result[BodyFraming, Http1Error] {
  let transfer = comma_values(headers.get_all_string("transfer-encoding"))
  let lengths = comma_values(headers.get_all_string("content-length"))
  if !transfer.is_empty() && !lengths.is_empty() {
    return Err(InvalidFraming("transfer-encoding and content-length conflict"))
  }
  if !transfer.is_empty() {
    if transfer[transfer.length() - 1].to_lower() != "chunked" {
      return Err(InvalidFraming("final transfer coding is not chunked"))
    }
    if transfer.length() != 1 {
      return Err(InvalidFraming("unsupported transfer coding"))
    }
    return Ok(Chunked)
  }
  if lengths.is_empty() {
    return Ok(NoBody)
  }
  let mut length = -1
  for value in lengths {
    let parsed = match parse_content_length_value(value) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if parsed < 0 || (length >= 0 && parsed != length) {
      return Err(InvalidFraming("inconsistent content-length"))
    }
    length = parsed
  }
  Ok(ContentLength(length))
}

///|
pub fn RequestDecoder::next(
  self : RequestDecoder,
) -> Result[RequestEvent?, Http1Error] {
  match self.state {
    RequestStart => {
      let line = match self.buffer.read_line(self.limits.max_start_line) {
        Ok(line) => line
        Err(NeedMore) => {
          if self.eof && self.buffer.length() > 0 {
            return Err(UnexpectedEof("request line"))
          }
          return Ok(None)
        }
        Err(_) => return Err(LimitExceeded("request line"))
      }
      let (http_method, uri, version) = match parse_request_line(line) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      self.state = RequestHeaders(
        http_method,
        uri,
        version,
        @types.HeaderMap::new(),
        0,
        0,
      )
      self.next()
    }
    RequestHeaders(http_method, uri, version, headers, count, bytes) => {
      let line = match self.buffer.read_line(self.limits.max_header_line) {
        Ok(line) => line
        Err(NeedMore) => {
          if self.eof {
            return Err(UnexpectedEof("request headers"))
          }
          return Ok(None)
        }
        Err(_) => return Err(LimitExceeded("request header line"))
      }
      if line.is_empty() {
        if version == Http11 && headers.get_string("host") is None {
          return Err(InvalidHeader("HTTP/1.1 request requires Host"))
        }
        let framing = match determine_request_framing(headers) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        if framing is ContentLength(size) && size > self.limits.max_body_bytes {
          return Err(LimitExceeded("message body"))
        }
        self.state = RequestBody(BodyDecoder::new(framing, self.limits))
        Ok(Some(RequestHead({ http_method, uri, version, headers, body: () })))
      } else {
        if count + 1 > self.limits.max_header_count ||
          bytes + line.length() + 2 > self.limits.max_header_bytes {
          return Err(LimitExceeded("request headers"))
        }
        match decode_header_line(line, headers) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
        self.state = RequestHeaders(
          http_method,
          uri,
          version,
          headers,
          count + 1,
          bytes + line.length() + 2,
        )
        self.next()
      }
    }
    RequestBody(body) => {
      let event = match body.next(self.buffer) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      match event {
        None => Ok(None)
        Some(Data(data)) => Ok(Some(RequestData(data)))
        Some(Trailers(headers)) => Ok(Some(RequestTrailers(headers)))
        Some(End) => {
          self.state = RequestStart
          Ok(Some(RequestEnd))
        }
      }
    }
  }
}

///|
pub enum ResponseState {
  ResponseStart
  ResponseHeaders(Int, @types.Version, @types.HeaderMap, Int, Int)
  ResponseBodyState(BodyDecoder)
}

///|
pub struct ResponseDecoder {
  buffer : @codec.Buffer
  mut state : ResponseState
  limits : @types.Limits
  request_method : @types.Method
  mut eof : Bool
}

///|
pub fn ResponseDecoder::new(
  request_method : @types.Method,
  limits? : @types.Limits = @types.Limits::defaults(),
) -> ResponseDecoder {
  {
    buffer: @codec.Buffer::new(max_bytes=limits.max_buffer_bytes),
    state: ResponseStart,
    limits,
    request_method,
    eof: false,
  }
}

///|
pub fn ResponseDecoder::feed(
  self : ResponseDecoder,
  bytes : BytesView,
) -> Result[Unit, Http1Error] {
  match self.buffer.feed(bytes) {
    Ok(_) => Ok(())
    Err(_) => Err(LimitExceeded("connection buffer"))
  }
}

///|
pub fn ResponseDecoder::finish_input(self : ResponseDecoder) -> Unit {
  self.eof = true
  match self.state {
    ResponseBodyState(body) => body.finish_input()
    _ => ()
  }
}

///|
fn parse_response_line(
  line : Bytes,
) -> Result[(@types.Version, Int), Http1Error] {
  let mut first = -1
  let mut second = line.length()
  for i in 0..<line.length() {
    if line[i] == b' ' {
      if first < 0 {
        first = i
      } else {
        second = i
        break
      }
    }
  }
  if first <= 0 || second != first + 4 {
    return Err(InvalidStartLine("invalid status line"))
  }
  let version = match parse_version(line[:first].to_owned()) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let status_string = @utf8.decode(line[first + 1:second]) catch {
    _ => return Err(InvalidStartLine("invalid status code"))
  }
  for byte in @utf8.encode(status_string) {
    if byte < b'0' || byte > b'9' {
      return Err(InvalidStartLine("invalid status code"))
    }
  }
  let status = @string.parse_int(status_string) catch {
    _ => return Err(InvalidStartLine("invalid status code"))
  }
  if status < 100 || status > 999 {
    return Err(InvalidStartLine("status code is out of range"))
  }
  Ok((version, status))
}

///|
fn determine_response_framing(
  headers : @types.HeaderMap,
  http_method : @types.Method,
  status : Int,
) -> Result[BodyFraming, Http1Error] {
  if !@types.response_allows_body(http_method, status) {
    return Ok(NoBody)
  }
  let transfer = comma_values(headers.get_all_string("transfer-encoding"))
  let lengths = comma_values(headers.get_all_string("content-length"))
  if !transfer.is_empty() && !lengths.is_empty() {
    return Err(InvalidFraming("transfer-encoding and content-length conflict"))
  }
  if !transfer.is_empty() {
    if transfer[transfer.length() - 1].to_lower() != "chunked" {
      return Ok(CloseDelimited)
    }
    if transfer.length() != 1 {
      return Err(InvalidFraming("unsupported transfer coding"))
    }
    return Ok(Chunked)
  }
  if lengths.is_empty() {
    return Ok(CloseDelimited)
  }
  determine_request_framing(headers)
}

///|
pub fn ResponseDecoder::next(
  self : ResponseDecoder,
) -> Result[ResponseEvent?, Http1Error] {
  match self.state {
    ResponseStart => {
      let line = match self.buffer.read_line(self.limits.max_start_line) {
        Ok(line) => line
        Err(NeedMore) => {
          if self.eof && self.buffer.length() > 0 {
            return Err(UnexpectedEof("status line"))
          }
          return Ok(None)
        }
        Err(_) => return Err(LimitExceeded("status line"))
      }
      let (version, status) = match parse_response_line(line) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      self.state = ResponseHeaders(
        status,
        version,
        @types.HeaderMap::new(),
        0,
        0,
      )
      self.next()
    }
    ResponseHeaders(status, version, headers, count, bytes) => {
      let line = match self.buffer.read_line(self.limits.max_header_line) {
        Ok(line) => line
        Err(NeedMore) => {
          if self.eof {
            return Err(UnexpectedEof("response headers"))
          }
          return Ok(None)
        }
        Err(_) => return Err(LimitExceeded("response header line"))
      }
      if line.is_empty() {
        let framing = match
          determine_response_framing(headers, self.request_method, status) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        if framing is ContentLength(size) && size > self.limits.max_body_bytes {
          return Err(LimitExceeded("message body"))
        }
        self.state = ResponseBodyState(BodyDecoder::new(framing, self.limits))
        Ok(Some(ResponseHead({ status, version, headers, body: () })))
      } else {
        if count + 1 > self.limits.max_header_count ||
          bytes + line.length() + 2 > self.limits.max_header_bytes {
          return Err(LimitExceeded("response headers"))
        }
        match decode_header_line(line, headers) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
        self.state = ResponseHeaders(
          status,
          version,
          headers,
          count + 1,
          bytes + line.length() + 2,
        )
        self.next()
      }
    }
    ResponseBodyState(body) => {
      let event = match body.next(self.buffer) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      match event {
        None => Ok(None)
        Some(Data(data)) => Ok(Some(ResponseData(data)))
        Some(Trailers(headers)) => Ok(Some(ResponseTrailers(headers)))
        Some(End) => {
          self.state = ResponseStart
          Ok(Some(ResponseEnd))
        }
      }
    }
  }
}

///|
fn push_bytes(out : Array[Byte], bytes : BytesView) -> Unit {
  for byte in bytes {
    out.push(byte)
  }
}

///|
fn push_text(out : Array[Byte], text : String) -> Unit {
  push_bytes(out, @utf8.encode(text))
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
fn version_text(version : @types.Version) -> String {
  match version {
    Http10 => "HTTP/1.0"
    Http11 => "HTTP/1.1"
    Http2 => "HTTP/2"
  }
}

///|
fn append_headers(
  out : Array[Byte],
  headers : @types.HeaderMap,
  framing : BodyFraming,
) -> Result[Unit, Http1Error] {
  for field in headers.fields() {
    let name = field.name.value
    if name == "content-length" || name == "transfer-encoding" {
      continue
    }
    push_text(out, name)
    push_text(out, ": ")
    push_bytes(out, field.value.bytes)
    push_text(out, "\r\n")
  }
  match framing {
    ContentLength(size) =>
      push_text(out, "content-length: " + size.to_string() + "\r\n")
    Chunked => push_text(out, "transfer-encoding: chunked\r\n")
    NoBody | CloseDelimited => ()
  }
  Ok(())
}

///|
pub fn encode_request_head(
  request : @types.Request[Unit],
  framing : BodyFraming,
) -> Result[Bytes, Http1Error] {
  if framing is CloseDelimited {
    return Err(InvalidFraming("requests cannot be close-delimited"))
  }
  let out : Array[Byte] = []
  push_text(
    out,
    method_text(request.http_method) +
    " " +
    request.uri.value +
    " " +
    version_text(request.version) +
    "\r\n",
  )
  match append_headers(out, request.headers, framing) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  push_text(out, "\r\n")
  Ok(Bytes::from_array(out))
}

///|
fn default_reason(status : Int) -> String {
  match status {
    100 => "Continue"
    101 => "Switching Protocols"
    200 => "OK"
    201 => "Created"
    204 => "No Content"
    304 => "Not Modified"
    400 => "Bad Request"
    404 => "Not Found"
    413 => "Payload Too Large"
    500 => "Internal Server Error"
    502 => "Bad Gateway"
    503 => "Service Unavailable"
    _ => "Unknown"
  }
}

///|
pub fn encode_response_head(
  response : @types.Response[Unit],
  request_method : @types.Method,
  framing : BodyFraming,
) -> Result[Bytes, Http1Error] {
  if !@types.response_allows_body(request_method, response.status) &&
    framing != NoBody {
    return Err(
      InvalidFraming("response status or request method forbids a body"),
    )
  }
  let out : Array[Byte] = []
  push_text(
    out,
    version_text(response.version) +
    " " +
    response.status.to_string() +
    " " +
    default_reason(response.status) +
    "\r\n",
  )
  match append_headers(out, response.headers, framing) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  push_text(out, "\r\n")
  Ok(Bytes::from_array(out))
}

///|
pub fn encode_body_data(
  data : Bytes,
  framing : BodyFraming,
) -> Result[Bytes, Http1Error] {
  match framing {
    NoBody =>
      if data.is_empty() {
        Ok(b"")
      } else {
        Err(InvalidFraming("body data for no-body message"))
      }
    ContentLength(_) | CloseDelimited => Ok(data)
    Chunked => {
      if data.is_empty() {
        return Ok(b"")
      }
      let out : Array[Byte] = []
      push_text(out, data.length().to_string(radix=16) + "\r\n")
      push_bytes(out, data)
      push_text(out, "\r\n")
      Ok(Bytes::from_array(out))
    }
  }
}

///|
pub fn encode_body_end(
  framing : BodyFraming,
  trailers? : @types.HeaderMap = @types.HeaderMap::new(),
) -> Result[Bytes, Http1Error] {
  if framing != Chunked {
    if !trailers.is_empty() {
      return Err(InvalidFraming("trailers require chunked framing"))
    }
    return Ok(b"")
  }
  let out : Array[Byte] = []
  push_text(out, "0\r\n")
  for field in trailers.fields() {
    if field.name.value == "content-length" ||
      field.name.value == "transfer-encoding" ||
      field.name.value == "host" {
      return Err(InvalidHeader("forbidden trailer field"))
    }
    push_text(out, field.name.value + ": ")
    push_bytes(out, field.value.bytes)
    push_text(out, "\r\n")
  }
  push_text(out, "\r\n")
  Ok(Bytes::from_array(out))
}
