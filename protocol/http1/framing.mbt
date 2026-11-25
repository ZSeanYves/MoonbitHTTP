///|
priv enum ResponseFramingRule {
  Payload
  RepresentationMetadata
  EmptyResponse
  ConnectTunnel
}

///|
fn response_framing_rule(
  request_method : @types.Method,
  status : Int32,
) -> ResponseFramingRule {
  if request_method == Connect && status >= 200 && status < 300 {
    ConnectTunnel
  } else if status < 200 || status == 204 {
    EmptyResponse
  } else if request_method == Head || status == 304 {
    RepresentationMetadata
  } else {
    Payload
  }
}

///|
priv enum FramingFields {
  Unspecified
  Length(Int32)
  LargeLength
  Transfer(Array[@types.HeaderValue])
}

///|
fn framing_fields(
  headers : @types.HeaderMap,
  version : @types.Version,
) -> Result[FramingFields, Http1Error] {
  let length : FramingFields = match headers.body_content_length() {
    Ok(Some(size)) => Length(size)
    Ok(None) => Unspecified
    Err(ContentLengthOverflow) => LargeLength
    Err(_) =>
      return Err(InvalidFraming("invalid or conflicting content-length"))
  }
  let transfer = headers.get_all_string("transfer-encoding")
  if transfer.is_empty() {
    Ok(length)
  } else if !(length is Unspecified) {
    Err(InvalidFraming("transfer-encoding and content-length conflict"))
  } else if version == Http10 {
    Err(InvalidFraming("HTTP/1.0 does not support Transfer-Encoding"))
  } else {
    Ok(Transfer(transfer))
  }
}

///|
fn FramingFields::body_framing(
  self : FramingFields,
  implicit : BodyFraming,
) -> Result[BodyFraming, Http1Error] {
  match self {
    Unspecified => Ok(implicit)
    Length(size) => Ok(ContentLength(size))
    LargeLength =>
      Err(InvalidFraming("content-length exceeds supported payload length"))
    Transfer([value]) if value
      .to_string_lossy()
      .trim(chars=" \t")
      .to_owned()
      .to_lower() ==
      "chunked" => Ok(Chunked)
    Transfer(_) => Err(InvalidFraming("unsupported transfer coding"))
  }
}

///|
fn determine_request_framing(
  headers : @types.HeaderMap,
  version : @types.Version,
) -> Result[BodyFraming, Http1Error] {
  match framing_fields(headers, version) {
    Ok(fields) => fields.body_framing(NoBody)
    Err(error) => Err(error)
  }
}

///|
fn determine_response_framing(
  headers : @types.HeaderMap,
  http_method : @types.Method,
  status : Int32,
  version : @types.Version,
) -> Result[BodyFraming, Http1Error] {
  let rule = response_framing_rule(http_method, status)
  // RFC 9112 §6.3: after successful CONNECT all following bytes belong to the tunnel.
  if rule is ConnectTunnel {
    return Ok(NoBody)
  }
  let fields = match framing_fields(headers, version) {
    Ok(fields) => fields
    Err(error) => return Err(error)
  }
  match rule {
    EmptyResponse if !(fields is Unspecified) =>
      Err(InvalidFraming("body framing header is forbidden for this response"))
    Payload => fields.body_framing(CloseDelimited)
    _ => Ok(NoBody)
  }
}

///|
/// Validate the selected wire framing before the encoder generates its fields.
fn validate_outgoing_framing(
  headers : @types.HeaderMap,
  framing : BodyFraming,
  version : @types.Version,
  rule~ : ResponseFramingRule = Payload,
) -> Result[Unit, Http1Error] {
  let fields = match framing_fields(headers, version) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !(rule is Payload) {
    if framing != NoBody {
      return Err(
        InvalidFraming("response status or request method forbids a body"),
      )
    }
    if !(rule is RepresentationMetadata) && !(fields is Unspecified) {
      return Err(
        InvalidFraming("body framing header is forbidden for this response"),
      )
    }
    return Ok(())
  }
  match framing {
    Chunked if version == Http10 =>
      return Err(InvalidFraming("HTTP/1.0 does not support chunked framing"))
    ContentLength(size) if size < 0 =>
      return Err(InvalidFraming("negative content-length"))
    _ => ()
  }
  match fields.body_framing(framing) {
    Ok(declared) if declared == framing ||
      (framing is NoBody && declared is ContentLength(0)) => Ok(())
    Ok(_) =>
      Err(InvalidFraming("header fields disagree with selected body framing"))
    Err(error) => Err(error)
  }
}
