///|
fn digest_is_ows(byte : Byte) -> Bool {
  byte == b' ' || byte == b'\t'
}

///|
fn digest_is_token(byte : Byte) -> Bool {
  let value = byte.to_int()
  (value >= 48 && value <= 57) ||
  (value >= 65 && value <= 90) ||
  (value >= 97 && value <= 122) ||
  byte == b'!' ||
  byte == b'#' ||
  byte == b'$' ||
  byte == b'%' ||
  byte == b'&' ||
  byte == b'\'' ||
  byte == b'*' ||
  byte == b'+' ||
  byte == b'-' ||
  byte == b'.' ||
  byte == b'^' ||
  byte == b'_' ||
  byte == b'`' ||
  byte == b'|' ||
  byte == b'~'
}

///|
fn digest_lower_ascii(input : BytesView) -> String? {
  let output = FixedArray::make(input.length(), b'0')
  for index in 0..<input.length() {
    let byte = input[index]
    if byte > b'\x7f' {
      return None
    }
    output[index] = if byte >= b'A' && byte <= b'Z' {
      (byte.to_int() + 32).to_byte()
    } else {
      byte
    }
  }
  Some(
    @utf8.decode(output.unsafe_reinterpret_as_bytes()) catch {
      _ => return None
    },
  )
}

///|
fn digest_decode_parameter(input : BytesView) -> String? {
  if auth_has_control(input) {
    return None
  }
  Some(@utf8.decode(input) catch { _ => return None })
}

///|
fn digest_parse_parameters(
  input : BytesView,
  start : Int,
  limits : AuthLimits,
) -> Result[Map[String, String], AuthError] {
  let parameters : Map[String, String] = Map([])
  let mut cursor = start
  while cursor < input.length() {
    while cursor < input.length() &&
          (digest_is_ows(input[cursor]) || input[cursor] == b',') {
      cursor += 1
    }
    if cursor == input.length() {
      break
    }
    let name_start = cursor
    while cursor < input.length() && digest_is_token(input[cursor]) {
      cursor += 1
    }
    if cursor == name_start {
      return Err(InvalidChallenge)
    }
    let name = match digest_lower_ascii(input[name_start:cursor]) {
      Some(value) => value
      None => return Err(InvalidChallenge)
    }
    while cursor < input.length() && digest_is_ows(input[cursor]) {
      cursor += 1
    }
    if cursor == input.length() || input[cursor] != b'=' {
      return Err(InvalidChallenge)
    }
    cursor += 1
    while cursor < input.length() && digest_is_ows(input[cursor]) {
      cursor += 1
    }
    let value_bytes : Array[Byte] = []
    if cursor < input.length() && input[cursor] == b'"' {
      cursor += 1
      let mut closed = false
      while cursor < input.length() {
        let byte = input[cursor]
        cursor += 1
        if byte == b'"' {
          closed = true
          break
        }
        if byte == b'\\' {
          if cursor == input.length() {
            return Err(InvalidChallenge)
          }
          let escaped = input[cursor]
          cursor += 1
          if escaped == b'\r' || escaped == b'\n' {
            return Err(InvalidChallenge)
          }
          value_bytes.push(escaped)
        } else {
          if byte == b'\r' || byte == b'\n' || byte == b'\x7f' || byte < b' ' {
            return Err(InvalidChallenge)
          }
          value_bytes.push(byte)
        }
        if value_bytes.length() > limits.max_parameter_bytes {
          return Err(ChallengeParameterTooLarge)
        }
      }
      if !closed {
        return Err(InvalidChallenge)
      }
    } else {
      let value_start = cursor
      while cursor < input.length() && digest_is_token(input[cursor]) {
        cursor += 1
      }
      if cursor == value_start ||
        cursor - value_start > limits.max_parameter_bytes {
        return Err(InvalidChallenge)
      }
      for byte in input[value_start:cursor] {
        value_bytes.push(byte)
      }
    }
    while cursor < input.length() && digest_is_ows(input[cursor]) {
      cursor += 1
    }
    if cursor < input.length() && input[cursor] != b',' {
      return Err(InvalidChallenge)
    }
    if parameters.get(name) is Some(_) {
      return Err(InvalidChallenge)
    }
    if parameters.length() >= limits.max_parameters {
      return Err(TooManyChallengeParameters)
    }
    let value = match digest_decode_parameter(Bytes::from_array(value_bytes)) {
      Some(value) => value
      None => return Err(InvalidChallenge)
    }
    parameters.set(name, value)
  }
  Ok(parameters)
}

///|
fn digest_algorithm(value : String) -> DigestAlgorithm? {
  match value.to_lower() {
    "md5" => Some(DigestMd5)
    "md5-sess" => Some(DigestMd5Sess)
    "sha-256" => Some(DigestSha256)
    "sha-256-sess" => Some(DigestSha256Sess)
    "sha-512-256" => Some(DigestSha512256)
    "sha-512-256-sess" => Some(DigestSha512256Sess)
    _ => None
  }
}

///|
fn digest_qops(value : String) -> Result[Array[DigestQop], AuthError] {
  let qops : Array[DigestQop] = []
  for raw in value.split(",") {
    match raw.trim(chars=" \t").to_owned().to_lower() {
      "auth" => if !qops.contains(DigestAuth) { qops.push(DigestAuth) }
      "auth-int" =>
        if !qops.contains(DigestAuthInt) {
          qops.push(DigestAuthInt)
        }
      _ => ()
    }
  }
  if qops.is_empty() {
    Err(UnsupportedDigestQop)
  } else {
    Ok(qops)
  }
}

///|
pub fn DigestChallenge::parse(
  header : @types.HeaderValue,
  limits? : AuthLimits = AuthLimits::defaults(),
) -> Result[DigestChallenge, AuthError] {
  match limits.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let input = header.bytes
  if input.length() > limits.max_challenge_bytes {
    return Err(ChallengeParameterTooLarge)
  }
  let mut cursor = 0
  while cursor < input.length() && digest_is_ows(input[cursor]) {
    cursor += 1
  }
  let scheme_start = cursor
  while cursor < input.length() && digest_is_token(input[cursor]) {
    cursor += 1
  }
  let scheme = match digest_lower_ascii(input[scheme_start:cursor]) {
    Some(value) => value
    None => return Err(InvalidChallenge)
  }
  if scheme != "digest" || cursor == scheme_start {
    return Err(InvalidChallenge)
  }
  let parameters = match digest_parse_parameters(input, cursor, limits) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let realm = match parameters.get("realm") {
    Some(value) => value
    None => return Err(MissingDigestRealm)
  }
  let nonce = match parameters.get("nonce") {
    Some(value) if !value.is_empty() => value
    _ => return Err(MissingDigestNonce)
  }
  let algorithm = match parameters.get("algorithm") {
    Some(value) =>
      match digest_algorithm(value) {
        Some(value) => value
        None => return Err(UnsupportedDigestAlgorithm)
      }
    None => DigestMd5
  }
  let qops = match parameters.get("qop") {
    Some(value) =>
      match digest_qops(value) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
    None => []
  }
  let utf8 = match parameters.get("charset") {
    Some(value) if value.to_lower() == "utf-8" => true
    Some(_) => return Err(UnsupportedDigestCharset)
    None => false
  }
  let userhash = parameters.get("userhash") is Some(value) &&
    value.to_lower() == "true"
  let stale = parameters.get("stale") is Some(value) &&
    value.to_lower() == "true"
  Ok({
    realm,
    nonce,
    opaque_value: parameters.get("opaque"),
    algorithm,
    qops,
    utf8,
    userhash,
    stale,
  })
}

///|
pub fn DigestChallenge::parse_string(
  header : String,
  limits? : AuthLimits = AuthLimits::defaults(),
) -> Result[DigestChallenge, AuthError] {
  let value = match @types.HeaderValue::from_string(header) {
    Ok(value) => value
    Err(_) => return Err(InvalidChallenge)
  }
  DigestChallenge::parse(value, limits~)
}
