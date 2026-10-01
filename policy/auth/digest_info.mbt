///|
fn digest_hex_length(algorithm : DigestAlgorithm) -> Int {
  match digest_base_algorithm(algorithm) {
    DigestMd5 => 32
    DigestSha256 | DigestSha512256 => 64
    _ => 0
  }
}

///|
fn digest_valid_lower_hex(value : String, expected_length : Int) -> Bool {
  let bytes = @utf8.encode(value)
  if bytes.length() != expected_length {
    return false
  }
  for byte in bytes {
    if !((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f')) {
      return false
    }
  }
  true
}

///|
/// Compares fixed-size response digests without a data-dependent early exit.
fn digest_constant_time_equal(left : String, right : String) -> Bool {
  let left_bytes = @utf8.encode(left)
  let right_bytes = @utf8.encode(right)
  if left_bytes.length() != right_bytes.length() {
    return false
  }
  let mut difference = 0
  for index in 0..<left_bytes.length() {
    difference = difference |
      (left_bytes[index].to_int() ^ right_bytes[index].to_int())
  }
  difference == 0
}

///|
fn digest_authentication_info_parameters(
  header : @types.HeaderValue,
  limits : AuthLimits,
) -> Result[Map[String, String], AuthError] {
  match limits.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if header.bytes.is_empty() {
    return Err(InvalidDigestAuthenticationInfo)
  }
  if header.bytes.length() > limits.max_challenge_bytes {
    return Err(ChallengeParameterTooLarge)
  }
  match digest_parse_parameters(header.bytes, 0, limits) {
    Ok(parameters) if !parameters.is_empty() => Ok(parameters)
    Ok(_) => Err(InvalidDigestAuthenticationInfo)
    Err(ChallengeParameterTooLarge) => Err(ChallengeParameterTooLarge)
    Err(TooManyChallengeParameters) => Err(TooManyChallengeParameters)
    Err(_) => Err(InvalidDigestAuthenticationInfo)
  }
}

///|
/// Validates a Digest `Authentication-Info` value against exactly the request
/// that produced this authorization context.
pub fn DigestAuthorization::verify_authentication_info(
  self : DigestAuthorization,
  header : @types.HeaderValue,
  response_entity_hash? : DigestEntityHash? = None,
  limits? : AuthLimits = AuthLimits::defaults(),
) -> Result[DigestAuthenticationInfo, AuthError] {
  let parameters = match digest_authentication_info_parameters(header, limits) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let next_nonce = match parameters.get("nextnonce") {
    Some(value) if value.is_empty() =>
      return Err(InvalidDigestAuthenticationInfo)
    value => value
  }
  let response_auth = parameters.get("rspauth")
  let response_authenticated = response_auth is Some(_)
  let response_a2 = match self.qop {
    Some(expected_qop) => {
      let expected_qop_name = match expected_qop {
        DigestAuth => "auth"
        DigestAuthInt => "auth-int"
      }
      let actual_qop = match parameters.get("qop") {
        Some(value) => value.to_lower()
        None => return Err(MissingDigestResponseAuth)
      }
      if actual_qop != expected_qop_name ||
        parameters.get("cnonce") != Some(self.cnonce) ||
        parameters.get("nc") != Some(self.nonce_count_text) {
        return Err(DigestAuthenticationContextMismatch)
      }
      if response_auth is None {
        return Err(MissingDigestResponseAuth)
      }
      match expected_qop {
        DigestAuth => ":" + self.request_target
        DigestAuthInt => {
          let base_algorithm = digest_base_algorithm(self.algorithm)
          let entity_hash = match response_entity_hash {
            Some(value) if value.algorithm == base_algorithm =>
              value.hexadecimal
            Some(_) => return Err(DigestEntityHashMismatch)
            None => return Err(DigestEntityHashRequired)
          }
          ":" + self.request_target + ":" + entity_hash
        }
      }
    }
    None => {
      if parameters.get("qop") is Some(_) ||
        parameters.get("cnonce") is Some(_) ||
        parameters.get("nc") is Some(_) {
        return Err(DigestAuthenticationContextMismatch)
      }
      ":" + self.request_target
    }
  }
  match response_auth {
    Some(actual) => {
      if !digest_valid_lower_hex(actual, digest_hex_length(self.algorithm)) {
        return Err(InvalidDigestAuthenticationInfo)
      }
      let ha2 = digest_hash_text(self.algorithm, response_a2)
      let expected = match self.qop {
        Some(qop) => {
          let qop_name = match qop {
            DigestAuth => "auth"
            DigestAuthInt => "auth-int"
          }
          digest_hash_text(
            self.algorithm,
            self.ha1 +
            ":" +
            self.nonce +
            ":" +
            self.nonce_count_text +
            ":" +
            self.cnonce +
            ":" +
            qop_name +
            ":" +
            ha2,
          )
        }
        None =>
          digest_hash_text(
            self.algorithm,
            self.ha1 + ":" + self.nonce + ":" + ha2,
          )
      }
      if !digest_constant_time_equal(actual, expected) {
        return Err(DigestResponseAuthMismatch)
      }
    }
    None => ()
  }
  if next_nonce is None && !response_authenticated {
    return Err(InvalidDigestAuthenticationInfo)
  }
  Ok({ next_nonce, response_authenticated, })
}

///|
/// Verifies the server response and adopts `nextnonce` atomically. A nonce
/// carried by an older concurrent response is rejected instead of silently
/// replacing newer session state.
pub fn DigestSession::verify_authentication_info(
  self : DigestSession,
  authorization : DigestAuthorization,
  header : @types.HeaderValue,
  response_entity_hash? : DigestEntityHash? = None,
  limits? : AuthLimits = AuthLimits::defaults(),
) -> Result[DigestAuthenticationInfo, AuthError] {
  if authorization.origin != self.origin ||
    authorization.realm != self.challenge.realm ||
    authorization.algorithm != self.challenge.algorithm {
    return Err(DigestAuthenticationContextMismatch)
  }
  let info = match
    authorization.verify_authentication_info(
      header,
      response_entity_hash~,
      limits~,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match info.next_nonce {
    Some(next_nonce) => {
      if authorization.nonce != self.challenge.nonce ||
        authorization.nonce_count != self.nonce_count {
        return Err(DigestNextNonceRace)
      }
      self.challenge = { ..self.challenge, nonce: next_nonce, stale: false, }
      self.nonce_count = 0L
    }
    None => ()
  }
  Ok(info)
}
