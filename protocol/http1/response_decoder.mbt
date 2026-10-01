///|
priv enum ResponseState {
  ResponseStart
  ResponseHeaders(Int, @types.Version, @types.HeaderMap, Int, Int)
  ResponseBodyState(BodyDecoder)
}

///|
pub struct ResponseDecoder {
  priv buffer : @codec.Buffer
  priv mut state : ResponseState
  priv limits : @types.Limits
  priv request_method : @types.Method
  priv mut eof : Bool
  priv mut failure : Http1Error?
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
