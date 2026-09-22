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
  { state, total: 0, limits, eof: false, }
}

///|
fn BodyDecoder::finish_input(self : BodyDecoder) -> Unit {
  self.eof = true
}

///|
fn http1_is_tchar(byte : Byte) -> Bool {
  let value = byte.to_int()
  (value >= 48 && value <= 57) ||
  (value >= 65 && value <= 90) ||
  (value >= 97 && value <= 122) ||
  byte == b'!' ||
  byte == b'#' ||
  byte == b'$' ||
  byte == b'%' ||
  byte == b'&' ||
  byte == b'\'' ||
  byte == b'*' ||
  byte == b'+' ||
  byte == b'-' ||
  byte == b'.' ||
  byte == b'^' ||
  byte == b'_' ||
  byte == b'`' ||
  byte == b'|' ||
  byte == b'~'
}

///|
/// RFC 9112 chunk extensions are intentionally parsed rather than ignored.
/// This prevents malformed extension bytes from becoming a second framing
/// interpretation in a downstream proxy.
fn parse_chunk_extension(
  input : BytesView,
  start : Int,
) -> Result[Unit, Http1Error] {
  let mut index = start
  while index < input.length() {
    while index < input.length() &&
          (input[index] == b' ' || input[index] == b'\t') {
      index += 1
    }
    if index >= input.length() || input[index] != b';' {
      return Err(InvalidFraming("invalid chunk extension"))
    }
    index += 1
    while index < input.length() &&
          (input[index] == b' ' || input[index] == b'\t') {
      index += 1
    }
    let name_start = index
    while index < input.length() && http1_is_tchar(input[index]) {
      index += 1
    }
    if index == name_start {
      return Err(InvalidFraming("invalid chunk extension name"))
    }
    while index < input.length() &&
          (input[index] == b' ' || input[index] == b'\t') {
      index += 1
    }
    if index < input.length() && input[index] == b'=' {
      index += 1
      while index < input.length() &&
            (input[index] == b' ' || input[index] == b'\t') {
        index += 1
      }
      if index >= input.length() {
        return Err(InvalidFraming("chunk extension value is missing"))
      }
      if input[index] == b'"' {
        index += 1
        let mut closed = false
        while index < input.length() {
          let byte = input[index]
          if byte == b'\\' {
            if index + 1 >= input.length() || input[index + 1] < 0x20 {
              return Err(InvalidFraming("invalid quoted chunk extension"))
            }
            index += 2
          } else if byte == b'"' {
            index += 1
            closed = true
            break
          } else if byte < 0x20 || byte == 0x7f {
            return Err(InvalidFraming("invalid quoted chunk extension"))
          } else {
            index += 1
          }
        }
        if !closed {
          return Err(InvalidFraming("unterminated chunk extension"))
        }
      } else {
        let value_start = index
        while index < input.length() && http1_is_tchar(input[index]) {
          index += 1
        }
        if index == value_start {
          return Err(InvalidFraming("invalid chunk extension value"))
        }
      }
      while index < input.length() &&
            (input[index] == b' ' || input[index] == b'\t') {
        index += 1
      }
    }
  }
  Ok(())
}

///|
fn parse_hex_size(line : Bytes) -> Result[Int, Http1Error] {
  let mut size = 0
  let mut digits = 0
  for byte in line {
    if byte == b';' {
      break
    }
    if byte == b' ' || byte == b'\t' {
      // OWS before the first extension delimiter is permitted.
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
    let mut end = digits
    while end < line.length() && (line[end] == b' ' || line[end] == b'\t') {
      end += 1
    }
    if end < line.length() {
      if line[end] != b';' {
        return Err(InvalidFraming("invalid chunk size extension"))
      }
      match parse_chunk_extension(line, end) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
    }
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
fn http1_forbidden_trailer(name : String) -> Bool {
  name == "content-length" ||
  name == "transfer-encoding" ||
  name == "host" ||
  name == "trailer" ||
  name == "connection" ||
  name == "keep-alive" ||
  name == "upgrade" ||
  name == "te" ||
  name == "proxy-authenticate" ||
  name == "proxy-authorization"
}

///|
fn http1_validate_trailer_fields(
  headers : @types.HeaderMap,
) -> Result[Unit, Http1Error] {
  for field in headers.fields() {
    if http1_forbidden_trailer(field.name.value) {
      return Err(InvalidHeader("forbidden trailer field"))
    }
  }
  Ok(())
}

///|
fn http1_validate_host(headers : @types.HeaderMap) -> Result[Unit, Http1Error] {
  let hosts = headers.get_all_string("host")
  if hosts.length() > 1 {
    return Err(InvalidHeader("request contains multiple Host fields"))
  }
  match hosts {
    [] => Ok(())
    [value] =>
      match
        @types.Authority::parse_endpoint(
          value.to_string_lossy().trim().to_owned(),
        ) {
        Ok(_) => Ok(())
        Err(_) => Err(InvalidHeader("invalid Host field"))
      }
    _ => Err(InvalidHeader("request contains multiple Host fields"))
  }
}

///|
fn http1_validate_connection_headers(
  headers : @types.HeaderMap,
) -> Result[Unit, Http1Error] {
  for value in headers.get_all_string("te") {
    for token in value.to_string_lossy().split(",") {
      let normalized = token.trim().to_owned().to_lower()
      if normalized != "trailers" && !normalized.is_empty() {
        return Err(InvalidHeader("unsupported TE request coding"))
      }
    }
  }
  for value in headers.get_all_string("trailer") {
    for token in value.to_string_lossy().split(",") {
      let name = token.trim().to_owned()
      match @types.HeaderName::parse(name) {
        Ok(parsed) if !http1_forbidden_trailer(parsed.value) => ()
        _ => return Err(InvalidHeader("invalid Trailer declaration"))
      }
    }
  }
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
      if self.total > self.limits.max_body_bytes ||
        size > self.limits.max_body_bytes - self.total {
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
        match http1_validate_trailer_fields(headers) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
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
        let count = buffer.length()
        if self.total > self.limits.max_body_bytes ||
          count > self.limits.max_body_bytes - self.total {
          return Err(LimitExceeded("close-delimited body"))
        }
        let data = buffer.take(count)
        self.total += count
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
  mut failure : Http1Error?
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
    failure: None,
  }
}

///|
pub fn RequestDecoder::feed(
  self : RequestDecoder,
  bytes : BytesView,
) -> Result[Unit, Http1Error] {
  if self.failure is Some(error) {
    return Err(error)
  }
  match self.buffer.feed(bytes) {
    Ok(_) => Ok(())
    Err(_) => {
      let error = LimitExceeded("connection buffer")
      self.failure = Some(error)
      Err(error)
    }
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
  match @types.Method::parse_bytes(bytes) {
    Ok(value) => Ok(value)
    Err(_) => Err(InvalidStartLine("invalid method token"))
  }
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
  let uri = match @types.Uri::parse_request_target(target, http_method) {
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
fn determine_request_framing(
  headers : @types.HeaderMap,
  version : @types.Version,
) -> Result[BodyFraming, Http1Error] {
  let transfer = comma_values(headers.get_all_string("transfer-encoding"))
  let length = match headers.content_length() {
    Ok(value) => value
    Err(_) =>
      return Err(InvalidFraming("invalid or conflicting content-length"))
  }
  if !transfer.is_empty() && length is Some(_) {
    return Err(InvalidFraming("transfer-encoding and content-length conflict"))
  }
  if !transfer.is_empty() {
    if version == Http10 {
      return Err(InvalidFraming("HTTP/1.0 does not support Transfer-Encoding"))
    }
    if transfer[transfer.length() - 1].to_lower() != "chunked" {
      return Err(InvalidFraming("final transfer coding is not chunked"))
    }
    if transfer.length() != 1 {
      return Err(InvalidFraming("unsupported transfer coding"))
    }
    return Ok(Chunked)
  }
  match length {
    None => Ok(NoBody)
    Some(value) => Ok(ContentLength(value))
  }
}

///|
fn RequestDecoder::next_impl(
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
      self.next_impl()
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
        match http1_validate_host(headers) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
        if version == Http11 && headers.get_all_string("host").is_empty() {
          return Err(InvalidHeader("HTTP/1.1 request requires Host"))
        }
        match http1_validate_connection_headers(headers) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
        let framing = match determine_request_framing(headers, version) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        if framing is ContentLength(size) && size > self.limits.max_body_bytes {
          return Err(LimitExceeded("message body"))
        }
        self.state = RequestBody(BodyDecoder::new(framing, self.limits))
        Ok(Some(RequestHead({ http_method, uri, version, headers, body: (), })))
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
        self.next_impl()
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
pub fn RequestDecoder::next(
  self : RequestDecoder,
) -> Result[RequestEvent?, Http1Error] {
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
  mut failure : Http1Error?
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
    failure: None,
  }
}

///|
pub fn ResponseDecoder::feed(
  self : ResponseDecoder,
  bytes : BytesView,
) -> Result[Unit, Http1Error] {
  if self.failure is Some(error) {
    return Err(error)
  }
  match self.buffer.feed(bytes) {
    Ok(_) => Ok(())
    Err(_) => {
      let error = LimitExceeded("connection buffer")
      self.failure = Some(error)
      Err(error)
    }
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
/// Returns bytes read past `ResponseEnd`; only use this when changing
/// protocols, such as after a successful CONNECT or 101 response.
pub fn ResponseDecoder::take_buffered(self : ResponseDecoder) -> Bytes {
  self.buffer.take(self.buffer.length())
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
  version : @types.Version,
) -> Result[BodyFraming, Http1Error] {
  let transfer = comma_values(headers.get_all_string("transfer-encoding"))
  let length = match headers.content_length() {
    Ok(value) => value
    Err(_) =>
      return Err(InvalidFraming("invalid or conflicting content-length"))
  }
  if !transfer.is_empty() && length is Some(_) {
    return Err(InvalidFraming("transfer-encoding and content-length conflict"))
  }
  let content_length_forbidden = (status >= 100 && status < 200) ||
    status == 204 ||
    (http_method == Connect && status >= 200 && status < 300)
  if content_length_forbidden {
    if length is Some(_) || !transfer.is_empty() {
      return Err(
        InvalidFraming("body framing header is forbidden for this response"),
      )
    }
    return Ok(NoBody)
  }
  if !@types.response_allows_body(http_method, status) {
    if !transfer.is_empty() {
      return Err(
        InvalidFraming("Transfer-Encoding is forbidden without a body"),
      )
    }
    return Ok(NoBody)
  }
  if !transfer.is_empty() {
    if version == Http10 {
      return Err(InvalidFraming("HTTP/1.0 does not support Transfer-Encoding"))
    }
    if transfer[transfer.length() - 1].to_lower() != "chunked" {
      return Err(InvalidFraming("unsupported transfer coding"))
    }
    if transfer.length() != 1 {
      return Err(InvalidFraming("unsupported transfer coding"))
    }
    return Ok(Chunked)
  }
  if length is None {
    return Ok(CloseDelimited)
  }
  determine_request_framing(headers, version)
}

///|
fn ResponseDecoder::next_impl(
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
      self.next_impl()
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
          determine_response_framing(
            headers,
            self.request_method,
            status,
            version,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        if framing is ContentLength(size) && size > self.limits.max_body_bytes {
          return Err(LimitExceeded("message body"))
        }
        self.state = ResponseBodyState(BodyDecoder::new(framing, self.limits))
        Ok(Some(ResponseHead({ status, version, headers, body: (), })))
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
        self.next_impl()
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
pub fn ResponseDecoder::next(
  self : ResponseDecoder,
) -> Result[ResponseEvent?, Http1Error] {
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
fn version_text(version : @types.Version) -> String {
  match version {
    Http10 => "HTTP/1.0"
    Http11 => "HTTP/1.1"
    Http2 => "HTTP/2"
    Http3 => "HTTP/3"
  }
}

///|
fn append_headers(
  out : Array[Byte],
  headers : @types.HeaderMap,
  framing : BodyFraming,
  preserve_content_length : Bool,
) -> Result[Unit, Http1Error] {
  for field in headers.fields() {
    let name = field.name.value
    if name == "transfer-encoding" ||
      (name == "content-length" && !preserve_content_length) {
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
/// Validates caller-supplied framing metadata before the encoder replaces the
/// wire-managed Content-Length/Transfer-Encoding fields. Silently discarding
/// contradictory metadata is a request-smuggling footgun.
fn validate_outgoing_framing(
  headers : @types.HeaderMap,
  framing : BodyFraming,
  version : @types.Version,
  allow_nonzero_content_length_without_body? : Bool = false,
) -> Result[Unit, Http1Error] {
  let transfer = comma_values(headers.get_all_string("transfer-encoding"))
  let length = match headers.content_length() {
    Ok(value) => value
    Err(_) =>
      return Err(InvalidFraming("invalid or conflicting content-length"))
  }
  if !transfer.is_empty() && length is Some(_) {
    return Err(InvalidFraming("transfer-encoding and content-length conflict"))
  }
  if version == Http10 && !transfer.is_empty() {
    return Err(InvalidFraming("HTTP/1.0 does not support Transfer-Encoding"))
  }
  match framing {
    NoBody =>
      if !transfer.is_empty() {
        return Err(InvalidFraming("Transfer-Encoding is not valid for no body"))
      } else {
        match length {
          Some(value) if value != 0 &&
            !allow_nonzero_content_length_without_body =>
            return Err(
              InvalidFraming("non-zero Content-Length requires a body"),
            )
          _ => ()
        }
      }
    ContentLength(size) =>
      match length {
        Some(value) if value != size =>
          return Err(
            InvalidFraming("Content-Length does not match body framing"),
          )
        _ => ()
      }
    Chunked => {
      if length is Some(_) {
        return Err(InvalidFraming("chunked body cannot include Content-Length"))
      }
      if !transfer.is_empty() &&
        (transfer.length() != 1 || transfer[0].to_lower() != "chunked") {
        return Err(InvalidFraming("unsupported transfer coding"))
      }
    }
    CloseDelimited =>
      if !transfer.is_empty() || length is Some(_) {
        return Err(InvalidFraming("close-delimited body has explicit framing"))
      }
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
  if request.version == Http2 || request.version == Http3 {
    return Err(InvalidStartLine("non-HTTP/1 version in HTTP/1 wire encoding"))
  }
  if request.http_method.validate() is Err(_) {
    return Err(InvalidStartLine("invalid request method"))
  }
  if request.uri.validate_request_target(request.http_method) is Err(_) {
    return Err(InvalidStartLine("invalid request target"))
  }
  match http1_validate_host(request.headers) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if request.version == Http11 &&
    request.headers.get_all_string("host").is_empty() {
    return Err(InvalidHeader("HTTP/1.1 request requires Host"))
  }
  match http1_validate_connection_headers(request.headers) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match validate_outgoing_framing(request.headers, framing, request.version) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let out : Array[Byte] = []
  push_text(
    out,
    request.http_method.as_str() +
    " " +
    request.uri.value +
    " " +
    version_text(request.version) +
    "\r\n",
  )
  match append_headers(out, request.headers, framing, false) {
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
  if response.version == Http2 || response.version == Http3 {
    return Err(InvalidStartLine("non-HTTP/1 version in HTTP/1 wire encoding"))
  }
  if response.status < 100 || response.status > 999 {
    return Err(InvalidStartLine("status code is out of range"))
  }
  if !@types.response_allows_body(request_method, response.status) &&
    framing != NoBody {
    return Err(
      InvalidFraming("response status or request method forbids a body"),
    )
  }
  if (response.status >= 100 && response.status < 200) ||
    response.status == 204 ||
    (
      request_method == Connect &&
      response.status >= 200 &&
      response.status < 300
    ) {
    if response.headers.content_length() is Ok(Some(_)) ||
      !response.headers.get_all_string("transfer-encoding").is_empty() {
      return Err(
        InvalidFraming("body framing header is forbidden for this response"),
      )
    }
  }
  let permit_head_length = request_method == Head || response.status == 304
  match
    validate_outgoing_framing(
      response.headers,
      framing,
      response.version,
      allow_nonzero_content_length_without_body=permit_head_length,
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
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
  let preserve_content_length = request_method == Head || response.status == 304
  match
    append_headers(out, response.headers, framing, preserve_content_length) {
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
    if http1_forbidden_trailer(field.name.value) {
      return Err(InvalidHeader("forbidden trailer field"))
    }
    push_text(out, field.name.value + ": ")
    push_bytes(out, field.value.bytes)
    push_text(out, "\r\n")
  }
  push_text(out, "\r\n")
  Ok(Bytes::from_array(out))
}
