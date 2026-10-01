///|
pub(all) suberror AuthError {
  InvalidAuthLimits
  InvalidBasicCredentials
  InvalidBearerToken
  InvalidChallenge
  TooManyChallengeParameters
  ChallengeParameterTooLarge
  MissingDigestRealm
  MissingDigestNonce
  UnsupportedDigestAlgorithm
  WeakDigestAlgorithmDenied
  UnsupportedDigestQop
  UnsupportedDigestCharset
  InvalidDigestCredentials
  InvalidDigestCnonce
  DigestNonceCountExhausted
  DigestOriginMismatch
  DigestEntityHashRequired
  DigestEntityHashMismatch
  DigestChallengeNotStale
  DigestRealmChanged
  InvalidDigestRequestUri
  InvalidDigestAuthenticationInfo
  MissingDigestResponseAuth
  DigestResponseAuthMismatch
  DigestAuthenticationContextMismatch
  DigestNextNonceRace
} derive(Eq, Debug)

///|
pub(all) struct AuthLimits {
  max_challenge_bytes : Int
  max_parameters : Int
  max_parameter_bytes : Int
  max_credential_bytes : Int
  max_token_bytes : Int
} derive(Eq, Debug)

///|
pub fn AuthLimits::defaults() -> AuthLimits {
  {
    max_challenge_bytes: 16384,
    max_parameters: 32,
    max_parameter_bytes: 8192,
    max_credential_bytes: 8192,
    max_token_bytes: 8192,
  }
}

///|
pub fn AuthLimits::validate(self : AuthLimits) -> Result[Unit, AuthError] {
  if self.max_challenge_bytes < 1 ||
    self.max_parameters < 1 ||
    self.max_parameter_bytes < 1 ||
    self.max_credential_bytes < 1 ||
    self.max_token_bytes < 1 ||
    self.max_parameter_bytes > self.max_challenge_bytes {
    Err(InvalidAuthLimits)
  } else {
    Ok(())
  }
}

///|
fn auth_has_control(value : BytesView) -> Bool {
  for byte in value {
    if byte < b' ' || byte == b'\x7f' {
      return true
    }
  }
  false
}

///|
fn auth_header(value : String) -> Result[@types.HeaderValue, AuthError] {
  match @types.HeaderValue::from_string(value) {
    Ok(header) => Ok(header)
    Err(_) => Err(InvalidChallenge)
  }
}
