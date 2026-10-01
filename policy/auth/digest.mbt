///|
fn digest_base_algorithm(algorithm : DigestAlgorithm) -> DigestAlgorithm {
  match algorithm {
    DigestMd5 | DigestMd5Sess => DigestMd5
    DigestSha256 | DigestSha256Sess => DigestSha256
    DigestSha512256 | DigestSha512256Sess => DigestSha512256
  }
}

///|
fn digest_session_algorithm(algorithm : DigestAlgorithm) -> Bool {
  algorithm == DigestMd5Sess ||
  algorithm == DigestSha256Sess ||
  algorithm == DigestSha512256Sess
}

///|
fn digest_algorithm_name(algorithm : DigestAlgorithm) -> String {
  match algorithm {
    DigestMd5 => "MD5"
    DigestMd5Sess => "MD5-sess"
    DigestSha256 => "SHA-256"
    DigestSha256Sess => "SHA-256-sess"
    DigestSha512256 => "SHA-512-256"
    DigestSha512256Sess => "SHA-512-256-sess"
  }
}

///|
fn digest_hash_bytes(algorithm : DigestAlgorithm, value : Bytes) -> Bytes {
  match digest_base_algorithm(algorithm) {
    DigestMd5 => @mooncry.md5(value)
    DigestSha256 => @mooncry.sha256(value)
    DigestSha512256 => @mooncry.sha512_256(value)
    _ => @mooncry.sha256(value)
  }
}

///|
fn digest_hash_text(algorithm : DigestAlgorithm, value : String) -> String {
  @mooncry.bytes_to_hex(digest_hash_bytes(algorithm, @utf8.encode(value)))
}

///|
fn digest_ascii_only(value : String) -> Bool {
  for byte in @utf8.encode(value) {
    if byte > b'\x7f' {
      return false
    }
  }
  true
}

///|
fn digest_validate_policy(
  challenge : DigestChallenge,
  policy : DigestPolicy,
) -> Result[Unit, AuthError] {
  match policy.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if (challenge.algorithm == DigestMd5 || challenge.algorithm == DigestMd5Sess) &&
    !policy.allow_md5 {
    return Err(WeakDigestAlgorithmDenied)
  }
  if challenge.qops.is_empty() && !policy.allow_legacy_no_qop {
    return Err(UnsupportedDigestQop)
  }
  if challenge.qops.is_empty() && digest_session_algorithm(challenge.algorithm) {
    return Err(UnsupportedDigestQop)
  }
  Ok(())
}

///|
pub fn DigestEntityHash::compute(
  algorithm : DigestAlgorithm,
  body : BytesView,
) -> DigestEntityHash {
  let base = digest_base_algorithm(algorithm)
  {
    algorithm: base,
    hexadecimal: @mooncry.bytes_to_hex(digest_hash_bytes(base, body.to_owned())),
  }
}

///|
pub fn DigestSession::new(
  challenge : DigestChallenge,
  credentials : DigestCredentials,
  origin : String,
  policy? : DigestPolicy = DigestPolicy::defaults(),
  limits? : AuthLimits = AuthLimits::defaults(),
) -> Result[DigestSession, AuthError] {
  match limits.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match digest_validate_policy(challenge, policy) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if origin.is_empty() || auth_has_control(@utf8.encode(origin)) {
    return Err(DigestOriginMismatch)
  }
  if !challenge.utf8 &&
    (
      !digest_ascii_only(credentials.username) ||
      !digest_ascii_only(credentials.password)
    ) {
    return Err(UnsupportedDigestCharset)
  }
  Ok({ challenge, credentials, origin, policy, limits, nonce_count: 0L, })
}

///|
fn digest_cnonce_valid(value : String, maximum : Int) -> Bool {
  let bytes = @utf8.encode(value)
  if bytes.is_empty() || bytes.length() > maximum {
    return false
  }
  for byte in bytes {
    if byte < b'!' || byte > b'~' {
      return false
    }
  }
  true
}

///|
fn digest_quote(value : String) -> String {
  let output = StringBuilder()
  output.write_char('"')
  for character in value {
    if character == '"' || character == '\\' {
      output.write_char('\\')
    }
    output.write_char(character)
  }
  output.write_char('"')
  output.to_string()
}

///|
fn digest_nonce_count(value : Int64) -> String {
  let digits = "0123456789abcdef"
  let output = FixedArray::make(8, b'0')
  let mut remaining = value
  for offset in 0..<8 {
    let digit = (remaining & 0x0fL).to_int()
    output[7 - offset] = digits[digit].to_int().to_byte()
    remaining = remaining >> 4
  }
  @utf8.decode(output.unsafe_reinterpret_as_bytes()) catch {
    _ => "00000000"
  }
}

///|
fn digest_select_qop(
  challenge : DigestChallenge,
  prefer_auth_int : Bool,
  entity_hash : DigestEntityHash?,
) -> Result[DigestQop?, AuthError] {
  if challenge.qops.is_empty() {
    return Ok(None)
  }
  if prefer_auth_int && challenge.supports_qop(DigestAuthInt) {
    if entity_hash is Some(_) {
      return Ok(Some(DigestAuthInt))
    }
    if !challenge.supports_qop(DigestAuth) {
      return Err(DigestEntityHashRequired)
    }
  }
  if challenge.supports_qop(DigestAuth) {
    return Ok(Some(DigestAuth))
  }
  if challenge.supports_qop(DigestAuthInt) {
    if entity_hash is Some(_) {
      Ok(Some(DigestAuthInt))
    } else {
      Err(DigestEntityHashRequired)
    }
  } else {
    Err(UnsupportedDigestQop)
  }
}

///|
pub fn DigestSession::authorize(
  self : DigestSession,
  origin : String,
  http_method : @types.Method,
  request_target : String,
  cnonce : String,
  entity_hash? : DigestEntityHash? = None,
) -> Result[DigestAuthorization, AuthError] {
  if origin != self.origin {
    return Err(DigestOriginMismatch)
  }
  match @types.Uri::parse_request_target(request_target, http_method) {
    Ok(_) => ()
    Err(_) => return Err(InvalidDigestRequestUri)
  }
  if !digest_cnonce_valid(cnonce, self.limits.max_parameter_bytes) {
    return Err(InvalidDigestCnonce)
  }
  if self.nonce_count >= self.policy.max_nonce_uses ||
    self.nonce_count >= 4294967295L {
    return Err(DigestNonceCountExhausted)
  }
  let qop = match
    digest_select_qop(self.challenge, self.policy.prefer_auth_int, entity_hash) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let base_algorithm = digest_base_algorithm(self.challenge.algorithm)
  if qop == Some(DigestAuthInt) {
    match entity_hash {
      Some(value) if value.algorithm == base_algorithm => ()
      Some(_) => return Err(DigestEntityHashMismatch)
      None => return Err(DigestEntityHashRequired)
    }
  }
  let username = if self.challenge.utf8 {
    @normalization.nfc(self.credentials.username)
  } else {
    self.credentials.username
  }
  let password = if self.challenge.utf8 {
    @normalization.nfc(self.credentials.password)
  } else {
    self.credentials.password
  }
  let initial_a1 = digest_hash_text(
    base_algorithm,
    username + ":" + self.challenge.realm + ":" + password,
  )
  let ha1 = if digest_session_algorithm(self.challenge.algorithm) {
    digest_hash_text(
      base_algorithm,
      initial_a1 + ":" + self.challenge.nonce + ":" + cnonce,
    )
  } else {
    initial_a1
  }
  let a2 = match qop {
    Some(DigestAuthInt) => {
      let hash = match entity_hash {
        Some(value) => value.hexadecimal
        None => return Err(DigestEntityHashRequired)
      }
      http_method.as_str() + ":" + request_target + ":" + hash
    }
    _ => http_method.as_str() + ":" + request_target
  }
  let ha2 = digest_hash_text(base_algorithm, a2)
  let next_count = self.nonce_count + 1L
  let nc = digest_nonce_count(next_count)
  let qop_name = match qop {
    Some(DigestAuth) => "auth"
    Some(DigestAuthInt) => "auth-int"
    None => ""
  }
  let response = match qop {
    Some(_) =>
      digest_hash_text(
        base_algorithm,
        ha1 +
        ":" +
        self.challenge.nonce +
        ":" +
        nc +
        ":" +
        cnonce +
        ":" +
        qop_name +
        ":" +
        ha2,
      )
    None =>
      digest_hash_text(
        base_algorithm,
        ha1 + ":" + self.challenge.nonce + ":" + ha2,
      )
  }
  let username_value = if self.challenge.userhash {
    digest_hash_text(base_algorithm, username + ":" + self.challenge.realm)
  } else {
    username
  }
  let output = StringBuilder()
  output.write_string("Digest username=")
  output.write_string(digest_quote(username_value))
  output.write_string(", realm=")
  output.write_string(digest_quote(self.challenge.realm))
  output.write_string(", uri=")
  output.write_string(digest_quote(request_target))
  output.write_string(", algorithm=")
  output.write_string(digest_algorithm_name(self.challenge.algorithm))
  output.write_string(", nonce=")
  output.write_string(digest_quote(self.challenge.nonce))
  match qop {
    Some(_) => {
      output.write_string(", nc=")
      output.write_string(nc)
      output.write_string(", cnonce=")
      output.write_string(digest_quote(cnonce))
      output.write_string(", qop=")
      output.write_string(qop_name)
    }
    None => ()
  }
  output.write_string(", response=")
  output.write_string(digest_quote(response))
  match self.challenge.opaque_value {
    Some(value) => {
      output.write_string(", opaque=")
      output.write_string(digest_quote(value))
    }
    None => ()
  }
  if self.challenge.userhash {
    output.write_string(", userhash=true")
  }
  let header = match auth_header(output.to_string()) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  self.nonce_count = next_count
  Ok({
    header,
    algorithm: self.challenge.algorithm,
    origin: self.origin,
    realm: self.challenge.realm,
    nonce: self.challenge.nonce,
    qop,
    cnonce,
    nonce_count: next_count,
    nonce_count_text: nc,
    request_target,
    ha1,
  })
}

///|
/// Creates a Digest request header without retaining response-verification
/// state. Use `authorize` when `Authentication-Info` will be validated.
pub fn DigestSession::authorization(
  self : DigestSession,
  origin : String,
  http_method : @types.Method,
  request_target : String,
  cnonce : String,
  entity_hash? : DigestEntityHash? = None,
) -> Result[@types.HeaderValue, AuthError] {
  match
    self.authorize(origin, http_method, request_target, cnonce, entity_hash~) {
    Ok(authorization) => Ok(authorization.header)
    Err(error) => Err(error)
  }
}

///|
pub fn DigestSession::replace_stale_challenge(
  self : DigestSession,
  challenge : DigestChallenge,
) -> Result[Unit, AuthError] {
  if !challenge.stale {
    return Err(DigestChallengeNotStale)
  }
  if challenge.realm != self.challenge.realm {
    return Err(DigestRealmChanged)
  }
  match digest_validate_policy(challenge, self.policy) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  self.challenge = challenge
  self.nonce_count = 0L
  Ok(())
}

///|
pub fn select_digest_challenge(
  headers : Array[@types.HeaderValue],
  policy? : DigestPolicy = DigestPolicy::defaults(),
  limits? : AuthLimits = AuthLimits::defaults(),
) -> Result[DigestChallenge, AuthError] {
  let mut last_error : AuthError = InvalidChallenge
  for header in headers {
    let challenge = match DigestChallenge::parse(header, limits~) {
      Ok(value) => value
      Err(error) => {
        last_error = error
        continue
      }
    }
    match digest_validate_policy(challenge, policy) {
      Ok(_) => return Ok(challenge)
      Err(error) => last_error = error
    }
  }
  Err(last_error)
}
