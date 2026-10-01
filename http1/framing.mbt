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
