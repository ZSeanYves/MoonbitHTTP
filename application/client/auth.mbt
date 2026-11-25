///|
/// Authentication state is keyed by the normalized origin. Credentials and
/// Digest nonce state therefore cannot be reused accidentally for a different
/// authority or scheme.
priv struct ClientDigestAuth {
  credentials : @auth.DigestCredentials
  policy : @auth.DigestPolicy
  limits : @auth.AuthLimits
  cnonce : () -> Result[String, @auth.AuthError]
  mut session : @auth.DigestSession?
}

///|
priv enum ClientAuthEntry {
  Basic(@auth.BasicCredentials)
  Bearer(@auth.BearerToken)
  Digest(ClientDigestAuth)
}

///|
priv struct ClientAuthStore {
  entries : Map[String, ClientAuthEntry]
}

///|
fn ClientAuthStore::new() -> ClientAuthStore {
  { entries: Map([]), }
}

///|
fn client_auth_error(error : @auth.AuthError) -> ClientError {
  ClientAuth(error)
}

///|
fn client_auth_origin(uri : @types.Uri) -> Result[String, ClientError] {
  match ClientEndpoint::from_uri(uri) {
    Ok(endpoint) => Ok(endpoint.origin)
    Err(error) => Err(error)
  }
}

///|
fn client_auth_set_header(
  headers : @types.HeaderMap,
  value : @types.HeaderValue,
) -> Result[Unit, ClientError] {
  let name = match @types.HeaderName::parse("authorization") {
    Ok(name) => name
    Err(_) => return Err(ClientInvalidOptions("invalid Authorization name"))
  }
  headers.set(name, value)
  Ok(())
}

///|
fn client_auth_request_target(uri : @types.Uri) -> Result[String, ClientError] {
  match uri.origin_form() {
    Ok(value) => Ok(value)
    Err(error) => Err(ClientInvalidUri(error))
  }
}

///|
/// Captures the session that signed this attempt, even if credentials change during the response.
priv struct SignedAttempt {
  session : @auth.DigestSession
  authorization : @auth.DigestAuthorization
}

///|
fn ClientAuthStore::wants_entity(
  self : ClientAuthStore,
  endpoint : ClientEndpoint,
) -> Bool {
  guard self.entries.get(endpoint.origin) is Some(Digest(auth)) &&
    auth.session is Some(session) else {
    return false
  }
  session.challenge.supports_qop(DigestAuthInt) &&
  (auth.policy.prefer_auth_int || !session.challenge.supports_qop(DigestAuth))
}

///|
fn ClientAuthStore::apply(
  self : ClientAuthStore,
  endpoint : ClientEndpoint,
  request_method : @types.Method,
  uri : @types.Uri,
  body : Bytes?,
  headers : @types.HeaderMap,
  explicit_authorization : Bool,
) -> Result[SignedAttempt?, ClientError] {
  let entry = match self.entries.get(endpoint.origin) {
    Some(value) => value
    None => return Ok(None)
  }
  match entry {
    Basic(credentials) => {
      if explicit_authorization {
        return Ok(None)
      }
      let value = match credentials.authorization() {
        Ok(value) => value
        Err(error) => return Err(client_auth_error(error))
      }
      match client_auth_set_header(headers, value) {
        Ok(_) => Ok(None)
        Err(error) => Err(error)
      }
    }
    Bearer(token) => {
      if explicit_authorization {
        return Ok(None)
      }
      let value = match token.authorization() {
        Ok(value) => value
        Err(error) => return Err(client_auth_error(error))
      }
      match client_auth_set_header(headers, value) {
        Ok(_) => Ok(None)
        Err(error) => Err(error)
      }
    }
    Digest(digest_value) => {
      let digest = digest_value
      if explicit_authorization {
        return Ok(None)
      }
      let session = match digest.session {
        Some(value) => value
        None => return Ok(None)
      }
      let target = match client_auth_request_target(uri) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let cnonce = match (digest.cnonce)() {
        Ok(value) => value
        Err(error) => return Err(client_auth_error(error))
      }
      let entity_hash = if self.wants_entity(endpoint) {
        body.map(data => {
          @auth.DigestEntityHash::compute(session.challenge.algorithm(), data)
        })
      } else {
        None
      }
      let authorization = match
        session.authorize(
          endpoint.origin,
          request_method,
          target,
          cnonce,
          entity_hash~,
        ) {
        Ok(value) => value
        Err(error) => return Err(client_auth_error(error))
      }
      let header = authorization.header()
      match client_auth_set_header(headers, header) {
        Ok(_) => Ok(Some({ session, authorization, }))
        Err(error) => Err(error)
      }
    }
  }
}

///|
fn client_digest_challenge_headers(
  headers : @types.HeaderMap,
) -> Array[@types.HeaderValue] {
  let result : Array[@types.HeaderValue] = []
  for value in headers.get_all_string("www-authenticate") {
    let text = value.to_string_lossy().trim(chars=" \t").to_owned()
    let lowered = text.to_lower()
    if lowered == "digest" || lowered.has_prefix("digest ") {
      result.push(value)
    }
  }
  result
}

///|
/// Consume a Digest challenge only for a configured Digest origin. A fresh
/// challenge cannot replace an established nonce; only an explicit stale
/// challenge may rotate it.
fn ClientAuthStore::handle_unauthorized(
  self : ClientAuthStore,
  endpoint : ClientEndpoint,
  headers : @types.HeaderMap,
) -> Result[Bool, ClientError] {
  let entry = match self.entries.get(endpoint.origin) {
    Some(value) => value
    None => return Ok(false)
  }
  let challenge_headers = client_digest_challenge_headers(headers)
  if challenge_headers.is_empty() {
    return Ok(false)
  }
  match entry {
    Digest(digest_value) => {
      let digest = digest_value
      let challenge = match
        @auth.select_digest_challenge(
          challenge_headers,
          policy=digest.policy,
          limits=digest.limits,
        ) {
        Ok(value) => value
        Err(error) => return Err(client_auth_error(error))
      }
      match digest.session {
        Some(session) => {
          if !challenge.stale() {
            return Ok(false)
          }
          match session.replace_stale_challenge(challenge) {
            Ok(_) => ()
            Err(error) => return Err(client_auth_error(error))
          }
          digest.session = Some(session)
        }
        None => {
          let session = match
            @auth.DigestSession::new(
              challenge,
              digest.credentials,
              endpoint.origin,
              policy=digest.policy,
              limits=digest.limits,
            ) {
            Ok(value) => value
            Err(error) => return Err(client_auth_error(error))
          }
          digest.session = Some(session)
        }
      }
      self.entries.set(endpoint.origin, Digest(digest))
      Ok(true)
    }
    _ => Ok(false)
  }
}

///|
/// Validate a Digest Authentication-Info field against the exact raw response
/// body. The body is hashed before content decoding, matching the wire entity
/// used by the Digest exchange.
fn SignedAttempt::verify(
  self : SignedAttempt,
  fields : Array[@types.HeaderValue],
  raw : Bytes,
) -> Unit raise ClientError {
  guard !fields.is_empty() else { return }
  guard fields.length() == 1 else {
    raise ClientAuth(InvalidDigestAuthenticationInfo)
  }
  let hash = if self.authorization.qop == Some(DigestAuthInt) {
    Some(@auth.DigestEntityHash::compute(self.authorization.algorithm, raw))
  } else {
    None
  }
  ignore(
    self.session
    .verify_authentication_info(
      self.authorization,
      fields[0],
      response_entity_hash=hash,
    )
    .map_err(client_auth_error)
    .unwrap_or_error(),
  )
}

///|
pub fn Client::set_basic_auth(
  self : Client,
  origin : @types.Uri,
  credentials : @auth.BasicCredentials,
) -> Result[Unit, ClientError] {
  let key = match client_auth_origin(origin) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  self.auth.entries.set(key, Basic(credentials))
  Ok(())
}

///|
pub fn Client::set_bearer_auth(
  self : Client,
  origin : @types.Uri,
  token : @auth.BearerToken,
) -> Result[Unit, ClientError] {
  let key = match client_auth_origin(origin) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  self.auth.entries.set(key, Bearer(token))
  Ok(())
}

///|
/// Configure Digest authentication. `cnonce` must return fresh, unpredictable
/// values; no deterministic fallback is provided by the library.
pub fn Client::set_digest_auth(
  self : Client,
  origin : @types.Uri,
  credentials : @auth.DigestCredentials,
  cnonce : () -> Result[String, @auth.AuthError],
  policy~ : @auth.DigestPolicy = @auth.DigestPolicy::defaults(),
  limits~ : @auth.AuthLimits = @auth.AuthLimits::defaults(),
) -> Result[Unit, ClientError] {
  match policy.validate() {
    Ok(_) => ()
    Err(error) => return Err(client_auth_error(error))
  }
  match limits.validate() {
    Ok(_) => ()
    Err(error) => return Err(client_auth_error(error))
  }
  let key = match client_auth_origin(origin) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  self.auth.entries.set(
    key,
    Digest({ credentials, policy, limits, cnonce, session: None, }),
  )
  Ok(())
}

///|
pub fn Client::clear_auth(
  self : Client,
  origin : @types.Uri,
) -> Result[Unit, ClientError] {
  let key = match client_auth_origin(origin) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  self.auth.entries.remove(key)
  Ok(())
}
