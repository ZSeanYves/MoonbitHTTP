///|
priv enum H3IncomingMessage {
  H3IncomingRequest
  H3IncomingResponse(String?)
}

///|
pub(all) enum H3MessagePhase {
  H3WaitingHeaders
  H3OpenBody
  H3TrailersReceived
  H3MessageComplete
  H3MessageCancelled
} derive(Eq, Debug)

///|
priv struct H3RequestStreamState {
  id : Int64
  incoming : H3IncomingMessage
  mut phase : H3MessagePhase
  mut expected_content_length : Int64?
  mut received_content_length : Int64
  mut body_forbidden : Bool
}

///|
fn H3RequestStreamState::new(
  id : Int64,
  incoming : H3IncomingMessage,
) -> H3RequestStreamState {
  {
    id,
    incoming,
    phase: H3WaitingHeaders,
    expected_content_length: None,
    received_content_length: 0L,
    body_forbidden: false,
  }
}

///|
fn H3RequestStreamState::receive_headers(
  self : H3RequestStreamState,
  fields : Array[QpackField],
  enable_connect_protocol : Bool,
) -> Result[(Bool, Bool), Http3Error] {
  if self.phase == H3WaitingHeaders {
    let kind = match self.incoming {
      H3IncomingRequest => H3RequestFields
      H3IncomingResponse(_) => H3ResponseFields
    }
    let request_method = match self.incoming {
      H3IncomingResponse(value) => value
      _ => None
    }
    let metadata = match
      validate_http3_field_section(
        self.id,
        fields,
        kind,
        request_method~,
        enable_connect_protocol~,
      ) {
      Ok(result) => result
      Err(error) => return Err(error)
    }
    if metadata.informational {
      if self.incoming is H3IncomingRequest {
        return Err(
          Http3StreamError(
            self.id,
            H3MessageError,
            "request headers cannot carry an informational status",
          ),
        )
      }
      return Ok((false, true))
    }
    self.phase = H3OpenBody
    self.expected_content_length = metadata.content_length
    self.body_forbidden = metadata.body_forbidden
    Ok((false, false))
  } else if self.phase == H3OpenBody {
    match validate_http3_field_section(self.id, fields, H3TrailerFields) {
      Ok(_) => {
        self.phase = H3TrailersReceived
        Ok((true, false))
      }
      Err(error) => Err(error)
    }
  } else {
    Err(
      Http3StreamError(
        self.id,
        H3FrameUnexpected,
        "HEADERS received after trailers or completion",
      ),
    )
  }
}

///|
fn H3RequestStreamState::receive_data(
  self : H3RequestStreamState,
  data : Bytes,
  max_body_bytes : Int,
) -> Result[Unit, Http3Error] {
  if self.phase != H3OpenBody {
    return Err(
      Http3StreamError(
        self.id,
        H3FrameUnexpected,
        "DATA received outside message body",
      ),
    )
  }
  if self.body_forbidden && !data.is_empty() {
    return Err(
      Http3StreamError(
        self.id,
        H3MessageError,
        "DATA is forbidden for this response",
      ),
    )
  }
  let length = data.length().to_int64()
  if self.received_content_length > max_body_bytes.to_int64() ||
    length > max_body_bytes.to_int64() - self.received_content_length {
    return Err(Http3LimitExceeded("HTTP/3 message body", max_body_bytes))
  }
  if self.expected_content_length is Some(expected) &&
    !self.body_forbidden &&
    (
      self.received_content_length > expected ||
      length > expected - self.received_content_length
    ) {
    return Err(
      Http3StreamError(self.id, H3MessageError, "DATA exceeds Content-Length"),
    )
  }
  self.received_content_length += length
  Ok(())
}

///|
fn H3RequestStreamState::finish(
  self : H3RequestStreamState,
) -> Result[Unit, Http3Error] {
  if self.phase == H3WaitingHeaders {
    return Err(
      Http3StreamError(
        self.id,
        H3RequestIncomplete,
        "request stream ended before final headers",
      ),
    )
  }
  if self.phase == H3MessageCancelled {
    return Ok(())
  }
  if self.expected_content_length is Some(expected) &&
    !self.body_forbidden &&
    self.received_content_length != expected {
    return Err(
      Http3StreamError(
        self.id,
        H3MessageError,
        "message body does not match Content-Length",
      ),
    )
  }
  self.phase = H3MessageComplete
  Ok(())
}

///|
fn H3RequestStreamState::cancel(self : H3RequestStreamState) -> Unit {
  self.phase = H3MessageCancelled
}
