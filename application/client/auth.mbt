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
  mut algorithm : @auth.DigestAlgorithm?
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
fn client_auth_digest_hash(
  algorithm : @auth.DigestAlgorithm,
  body : Bytes,
) -> @auth.DigestEntityHash {
  @auth.DigestEntityHash::compute(algorithm, body)
}

///|
/// Add the configured preemptive header, returning the Digest authorization
/// context when the request must later validate Authentication-Info.
fn ClientAuthStore::apply(
  self : ClientAuthStore,
  endpoint : ClientEndpoint,
  request_method : @types.Method,
  uri : @types.Uri,
  body : Bytes,
  headers : @types.HeaderMap,
  explicit_authorization : Bool,
) -> Result[@auth.DigestAuthorization?, ClientError] {
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
      let algorithm = match digest.algorithm {
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
      let entity_hash = client_auth_digest_hash(algorithm, body)
      let authorization = match
        session.authorize(
          endpoint.origin,
          request_method,
          target,
          cnonce,
          entity_hash=Some(entity_hash),
        ) {
        Ok(value) => value
        Err(error) => return Err(client_auth_error(error))
      }
      let header = authorization.header()
      match client_auth_set_header(headers, header) {
        Ok(_) => {
          // DigestSession mutates its nonce counter; write the value back to
          // make the state update explicit even if Map values are copied.
          digest.session = Some(session)
          self.entries.set(endpoint.origin, Digest(digest))
          Ok(Some(authorization))
        }
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
      let algorithm = challenge.algorithm()
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
          digest.algorithm = Some(algorithm)
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
          digest.algorithm = Some(algorithm)
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
fn ClientAuthStore::verify_response(
  self : ClientAuthStore,
  endpoint : ClientEndpoint,
  authorization : @auth.DigestAuthorization?,
  response : @types.Response[Bytes],
) -> Result[Unit, ClientError] {
  let authorization = match authorization {
    Some(value) => value
    None => return Ok(())
  }
  let entry = match self.entries.get(endpoint.origin) {
    Some(value) => value
    None => return Ok(())
  }
  let info_headers = response.headers.get_all_string("authentication-info")
  if info_headers.is_empty() {
    return Ok(())
  }
  if info_headers.length() != 1 {
    return Err(client_auth_error(InvalidDigestAuthenticationInfo))
  }
  match entry {
    Digest(digest_value) => {
      let digest = digest_value
      let session = match digest.session {
        Some(value) => value
        None =>
          return Err(client_auth_error(DigestAuthenticationContextMismatch))
      }
      let algorithm = match digest.algorithm {
        Some(value) => value
        None =>
          return Err(client_auth_error(DigestAuthenticationContextMismatch))
      }
      let entity_hash = client_auth_digest_hash(algorithm, response.body)
      match
        session.verify_authentication_info(
          authorization,
          info_headers[0],
          response_entity_hash=Some(entity_hash),
        ) {
        Ok(_) => {
          digest.session = Some(session)
          self.entries.set(endpoint.origin, Digest(digest))
          Ok(())
        }
        Err(error) => Err(client_auth_error(error))
      }
    }
    _ => Ok(())
  }
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
  self.config.auth.entries.set(key, Basic(credentials))
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
  self.config.auth.entries.set(key, Bearer(token))
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
  policy? : @auth.DigestPolicy = @auth.DigestPolicy::defaults(),
  limits? : @auth.AuthLimits = @auth.AuthLimits::defaults(),
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
  self.config.auth.entries.set(
    key,
    Digest({
      credentials,
      policy,
      limits,
      cnonce,
      session: None,
      algorithm: None,
    }),
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
  self.config.auth.entries.remove(key)
  Ok(())
}
