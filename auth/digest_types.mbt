///|
pub(all) enum DigestAlgorithm {
  DigestMd5
  DigestMd5Sess
  DigestSha256
  DigestSha256Sess
  DigestSha512256
  DigestSha512256Sess
} derive(Eq, Debug)

///|
pub(all) enum DigestQop {
  DigestAuth
  DigestAuthInt
} derive(Eq, Debug)

///|
pub(all) struct DigestPolicy {
  allow_md5 : Bool
  allow_legacy_no_qop : Bool
  prefer_auth_int : Bool
  max_nonce_uses : Int64
} derive(Eq, Debug)

///|
pub fn DigestPolicy::defaults() -> DigestPolicy {
  {
    allow_md5: false,
    allow_legacy_no_qop: false,
    prefer_auth_int: false,
    max_nonce_uses: 1000000L,
  }
}

///|
pub fn DigestPolicy::validate(self : DigestPolicy) -> Result[Unit, AuthError] {
  if self.max_nonce_uses < 1L || self.max_nonce_uses > 4294967295L {
    Err(DigestNonceCountExhausted)
  } else {
    Ok(())
  }
}

///|
pub struct DigestChallenge {
  realm : String
  nonce : String
  opaque_value : String?
  algorithm : DigestAlgorithm
  qops : Array[DigestQop]
  utf8 : Bool
  userhash : Bool
  stale : Bool
}

///|
pub fn DigestChallenge::algorithm(self : DigestChallenge) -> DigestAlgorithm {
  self.algorithm
}

///|
pub fn DigestChallenge::stale(self : DigestChallenge) -> Bool {
  self.stale
}

///|
pub fn DigestChallenge::supports_qop(
  self : DigestChallenge,
  qop : DigestQop,
) -> Bool {
  for candidate in self.qops {
    if candidate == qop {
      return true
    }
  }
  false
}

///|
pub struct DigestCredentials {
  username : String
  password : String
}

///|
pub fn DigestCredentials::new(
  username : String,
  password : String,
  limits? : AuthLimits = AuthLimits::defaults(),
) -> Result[DigestCredentials, AuthError] {
  match limits.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let username_bytes = @utf8.encode(username)
  let password_bytes = @utf8.encode(password)
  if auth_has_control(username_bytes) ||
    auth_has_control(password_bytes) ||
    username_bytes.length() >
    limits.max_credential_bytes - password_bytes.length() {
    Err(InvalidDigestCredentials)
  } else {
    Ok({ username, password, })
  }
}

///|
pub struct DigestEntityHash {
  algorithm : DigestAlgorithm
  hexadecimal : String
}

///|
pub struct DigestSession {
  mut challenge : DigestChallenge
  credentials : DigestCredentials
  origin : String
  policy : DigestPolicy
  limits : AuthLimits
  mut nonce_count : Int64
}

///|
pub fn DigestSession::nonce_count(self : DigestSession) -> Int64 {
  self.nonce_count
}

///|
/// A Digest request header together with the secret-derived state needed to
/// authenticate its corresponding response. This type deliberately has no
/// `Debug` implementation.
pub struct DigestAuthorization {
  header : @types.HeaderValue
  algorithm : DigestAlgorithm
  origin : String
  realm : String
  nonce : String
  qop : DigestQop?
  cnonce : String
  nonce_count : Int64
  nonce_count_text : String
  request_target : String
  ha1 : String
}

///|
pub fn DigestAuthorization::header(
  self : DigestAuthorization,
) -> @types.HeaderValue {
  self.header
}

///|
/// The validated information returned by the server. Its constructor is kept
/// private so callers cannot accidentally apply an unverified `nextnonce`.
pub struct DigestAuthenticationInfo {
  next_nonce : String?
  response_authenticated : Bool
}

///|
pub fn DigestAuthenticationInfo::next_nonce(
  self : DigestAuthenticationInfo,
) -> String? {
  self.next_nonce
}

///|
pub fn DigestAuthenticationInfo::response_authenticated(
  self : DigestAuthenticationInfo,
) -> Bool {
  self.response_authenticated
}
