///|
priv enum RequestState {
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
  priv buffer : @codec.Buffer
  priv mut state : RequestState
  priv limits : @types.Limits
  priv mut eof : Bool
  priv mut failure : Http1Error?
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
