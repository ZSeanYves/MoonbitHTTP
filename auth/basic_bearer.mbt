///|
pub struct BasicCredentials {
  username : String
  password : String
  limits : AuthLimits
}

///|
pub fn BasicCredentials::new(
  username : String,
  password : String,
  limits? : AuthLimits = AuthLimits::defaults(),
) -> Result[BasicCredentials, AuthError] {
  match limits.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let username_bytes = @utf8.encode(username)
  let password_bytes = @utf8.encode(password)
  if username.contains(":") ||
    auth_has_control(username_bytes) ||
    auth_has_control(password_bytes) ||
    username_bytes.length() >
    limits.max_credential_bytes - password_bytes.length() - 1 {
    return Err(InvalidBasicCredentials)
  }
  Ok({ username, password, limits, })
}

///|
pub fn BasicCredentials::authorization(
  self : BasicCredentials,
  utf8_charset? : Bool = false,
) -> Result[@types.HeaderValue, AuthError] {
  let username = if utf8_charset {
    @normalization.nfc(self.username)
  } else {
    self.username
  }
  let password = if utf8_charset {
    @normalization.nfc(self.password)
  } else {
    self.password
  }
  let credential = @utf8.encode(username + ":" + password)
  if credential.length() > self.limits.max_credential_bytes {
    return Err(InvalidBasicCredentials)
  }
  auth_header("Basic " + @base64.encode(credential))
}

///|
pub struct BearerToken {
  value : String
}

///|
pub fn BearerToken::new(
  value : String,
  limits? : AuthLimits = AuthLimits::defaults(),
) -> Result[BearerToken, AuthError] {
  match limits.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let bytes = @utf8.encode(value)
  if bytes.is_empty() || bytes.length() > limits.max_token_bytes {
    return Err(InvalidBearerToken)
  }
  let mut padding = false
  for byte in bytes {
    if byte == b'=' {
      padding = true
      continue
    }
    let alpha = (byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z')
    let digit = byte >= b'0' && byte <= b'9'
    if padding ||
      (
        !alpha &&
        !digit &&
        byte != b'-' &&
        byte != b'.' &&
        byte != b'_' &&
        byte != b'~' &&
        byte != b'+' &&
        byte != b'/'
      ) {
      return Err(InvalidBearerToken)
    }
  }
  Ok({ value, })
}

///|
pub fn BearerToken::authorization(
  self : BearerToken,
) -> Result[@types.HeaderValue, AuthError] {
  auth_header("Bearer " + self.value)
}
