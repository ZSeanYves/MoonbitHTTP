///|
/// A streaming body adapter that decodes content codings without collecting
/// the response. Trailers are held until every decoder reaches a clean end.
pub struct DecodedBody[B] {
  source : B
  decoder : ContentDecoderChain
  hint : @body.SizeHint
  mut source_done : Bool
  mut pending_trailers : @types.HeaderMap?
  mut terminal : Bool
  mut failure : Error?
}

///|
pub fn[B : @body.Body] DecodedBody::new(
  source : B,
  codings : Array[ContentCoding],
  limits? : ContentCodingLimits = ContentCodingLimits::defaults(),
) -> Result[DecodedBody[B], ContentCodingError] {
  let changes_length = codings.any(fn(coding) { coding != Identity })
  let hint = if changes_length {
    @body.SizeHint::unknown()
  } else {
    source.size_hint()
  }
  let decoder = match ContentDecoderChain::new(codings, limits~) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    source,
    decoder,
    hint,
    source_done: false,
    pending_trailers: None,
    terminal: false,
    failure: None,
  })
}

///|
fn[B : @body.Body] DecodedBody::remember_failure(
  self : DecodedBody[B],
  error : Error,
) -> Unit {
  if self.failure is None {
    self.failure = Some(error)
    self.source.cancel(error)
  }
}

///|
pub impl[B : @body.Body] @body.Body for DecodedBody[B] with fn next_frame(self) {
  match self.failure {
    Some(error) => raise error
    None => ()
  }
  if self.terminal {
    return None
  }
  for ;; {
    match self.decoder.poll() {
      Err(error) => {
        self.remember_failure(error)
        raise error
      }
      Ok(ContentDecoded(data)) => return Some(Data(data))
      Ok(ContentDecodeDone) =>
        match self.pending_trailers {
          Some(trailers) => {
            self.pending_trailers = None
            self.terminal = true
            return Some(Trailers(trailers))
          }
          None => {
            self.terminal = true
            return None
          }
        }
      Ok(ContentDecodeNeedInput) => {
        if self.source_done {
          let error = DecoderStalled(Identity)
          self.remember_failure(error)
          raise error
        }
        let next : Result[@body.Frame?, Error] = Ok(self.source.next_frame()) catch {
          error => Err(error)
        }
        match next {
          Err(error) => {
            self.remember_failure(error)
            raise error
          }
          Ok(Some(Data(data))) =>
            match self.decoder.feed(data) {
              Ok(_) => ()
              Err(error) => {
                self.remember_failure(error)
                raise error
              }
            }
          Ok(Some(Trailers(trailers))) => {
            self.source_done = true
            self.pending_trailers = Some(trailers)
            match self.decoder.feed(b"", end=true) {
              Ok(_) => ()
              Err(error) => {
                self.remember_failure(error)
                raise error
              }
            }
          }
          Ok(None) => {
            self.source_done = true
            match self.decoder.feed(b"", end=true) {
              Ok(_) => ()
              Err(error) => {
                self.remember_failure(error)
                raise error
              }
            }
          }
        }
      }
    }
  } nobreak {
    let error = DecoderStalled(Identity)
    self.remember_failure(error)
    raise error
  }
}

///|
pub impl[B : @body.Body] @body.Body for DecodedBody[B] with fn size_hint(self) {
  self.hint
}

///|
pub impl[B : @body.Body] @body.Body for DecodedBody[B] with fn cancel(
  self,
  error,
) {
  if !self.terminal && self.failure is None {
    self.failure = Some(error)
    self.source.cancel(error)
  }
}

///|
fn content_decoded_headers(
  source : @types.HeaderMap,
  remove_encoding : Bool,
) -> @types.HeaderMap {
  let result = @types.HeaderMap::new()
  for field in source.fields() {
    if remove_encoding &&
      (
        field.name.value == "content-encoding" ||
        field.name.value == "content-length"
      ) {
      continue
    }
    result.append(field.name, field.value)
  }
  result
}

///|
/// Parses and applies a response's `Content-Encoding`, removing stale
/// `Content-Encoding` and `Content-Length` metadata from the decoded response.
pub fn[B : @body.Body] decode_response(
  response : @types.Response[B],
  limits? : ContentCodingLimits = ContentCodingLimits::defaults(),
) -> Result[@types.Response[DecodedBody[B]], ContentCodingError] {
  let codings = match
    parse_content_codings(response.headers, max_codings=limits.max_codings) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let decoded = match DecodedBody::new(response.body, codings, limits~) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    status: response.status,
    version: response.version,
    headers: content_decoded_headers(response.headers, !codings.is_empty()),
    body: decoded,
  })
}

///|
/// Decode a bounded byte response without constructing a detached streaming
/// body. This is the facade used by byte-oriented clients; the streaming
/// `decode_response` function remains available when backpressure is needed.
pub fn decode_bytes_response(
  response : @types.Response[Bytes],
  limits? : ContentCodingLimits = ContentCodingLimits::defaults(),
) -> Result[@types.Response[Bytes], ContentCodingError] {
  let codings = match
    parse_content_codings(response.headers, max_codings=limits.max_codings) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let decoder = match ContentDecoderChain::new(codings, limits~) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match decoder.feed(response.body, end=true) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let output : Array[Byte] = []
  for ;; {
    let step = match decoder.poll() {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    match step {
      ContentDecoded(data) =>
        for byte in data {
          output.push(byte)
        }
      ContentDecodeDone => break
      ContentDecodeNeedInput => return Err(DecoderStalled(Identity))
    }
  }
  Ok({
    status: response.status,
    version: response.version,
    headers: content_decoded_headers(response.headers, !codings.is_empty()),
    body: Bytes::from_array(output),
  })
}
