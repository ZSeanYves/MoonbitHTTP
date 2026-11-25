///|
async fn ClientExchange::authenticated_response(
  self : ClientExchange,
  response : @types.Response[IncomingBody],
  digest : SignedAttempt?,
) -> @types.Response[IncomingBody] {
  guard digest is Some(signed) else { return response }
  let initial = response.headers.get_all_string("authentication-info")
  if signed.authorization.qop == Some(DigestAuthInt) ||
    response.headers.contains_list_token("trailer", "authentication-info") {
    let (raw, trailers) = @body.collect(
      response.body,
      max_bytes=self.client.options.limits.max_body_bytes,
    ) catch {
      @body.BodyLimitExceeded(limit~) => raise ClientBodyLimit(limit)
      error => raise error
    }
    if trailers is Some(fields) {
      initial.append(fields.get_all_string("authentication-info"))
    }
    signed.verify(initial, raw)
    return response.map_body(_ => saved_body(raw, trailers))
  }
  signed.verify(initial, b"")
  let source = response.body
  let read = async fn() {
    let frame = source.next_frame()
    if frame is Some(Trailers(fields)) &&
      !fields.get_all_string("authentication-info").is_empty() {
      if !initial.is_empty() {
        raise ClientAuth(InvalidDigestAuthenticationInfo)
      }
      signed.verify(fields.get_all_string("authentication-info"), b"")
    }
    frame
  }
  response.map_body(_ => {
    IncomingBody::new(read, source.size_hint(), reason => source.cancel(reason))
  })
}

///|
fn ClientExchange::deliver(
  self : ClientExchange,
  response : @types.Response[IncomingBody],
  fill : @cache.CacheFill?,
  upload : IncomingBody,
) -> @types.Response[IncomingBody] raise ClientError {
  let mut trailers = None
  let raw = response.body
  let commit = fill.bind(pending => {
    pending.prepare(response.map_body(_ => ()), self.now_seconds)
  })
  let tapped = match (fill, commit) {
    (Some(pending), Some(_)) =>
      IncomingBody::new(
        async fn() {
          let frame = raw.next_frame()
          match frame {
            Some(Data(data)) => pending.append(data)
            Some(Trailers(fields)) => trailers = Some(fields.copy())
            None => ()
          }
          frame
        },
        raw.size_hint(),
        reason => raw.cancel(reason),
      )
    _ => raw
  }
  let decoded = self.decode_response(response.map_body(_ => tapped))
  let body = decoded.body
  let delivered = IncomingBody::new(
    async fn() {
      let frame = body.next_frame()
      if frame is (None | Some(Trailers(_))) && commit is Some(finish) {
        finish(trailers)
      }
      frame
    },
    body.size_hint(),
    reason => {
      if fill is Some(pending) {
        pending.discard()
      }
      body.cancel(reason)
    },
    done=() => upload.cancel(@body.BodyError::Cancelled),
  )
  decoded.map_body(_ => delivered)
}
