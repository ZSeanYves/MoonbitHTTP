///|
pub(all) suberror AuthorityError {
  EmptyAuthority
  InvalidAuthority
  InvalidHost
  InvalidPort
} derive(Debug, Eq)

///|
/// A validated URI authority. `host` never contains brackets; `value` retains
/// the original spelling so callers can forward a request without rebuilding
/// it from normalized components.
pub(all) struct Authority {
  value : String
  userinfo : String?
  host : String
  port : Int?
  ip_literal : Bool
} derive(Debug, Eq)

///|
pub(all) enum UriForm {
  AsteriskForm
  OriginForm
  AbsoluteForm
  AuthorityForm
} derive(Debug, Eq)

///|
pub(all) struct Uri {
  value : String
  scheme : String?
  authority : Authority?
  path : String
  query : String?
  fragment : String?
  form : UriForm
} derive(Debug, Eq)

///|
pub(all) suberror UriError {
  InvalidUri(String)
  EmptyUri
  InvalidCharacter(offset~ : Int)
  InvalidPercentEncoding(offset~ : Int)
  InvalidScheme
  InvalidAuthority(AuthorityError)
  InvalidRequestTarget
  FragmentNotAllowed
  UserinfoNotAllowed
} derive(Debug, Eq)

///|
fn uri_is_alpha(byte : Byte) -> Bool {
  (byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z')
}

///|
fn uri_is_digit(byte : Byte) -> Bool {
  byte >= b'0' && byte <= b'9'
}

///|
fn uri_is_hex(byte : Byte) -> Bool {
  uri_is_digit(byte) ||
  (byte >= b'a' && byte <= b'f') ||
  (byte >= b'A' && byte <= b'F')
}

///|
fn uri_is_unreserved(byte : Byte) -> Bool {
  uri_is_alpha(byte) ||
  uri_is_digit(byte) ||
  byte == b'-' ||
  byte == b'.' ||
  byte == b'_' ||
  byte == b'~'
}

///|
fn uri_is_sub_delim(byte : Byte) -> Bool {
  byte == b'!' ||
  byte == b'$' ||
  byte == b'&' ||
  byte == b'\'' ||
  byte == b'(' ||
  byte == b')' ||
  byte == b'*' ||
  byte == b'+' ||
  byte == b',' ||
  byte == b';' ||
  byte == b'='
}

///|
fn ascii_lower(value : BytesView) -> String {
  let out : Array[Byte] = []
  for byte in value {
    out.push(
      if byte >= b'A' && byte <= b'Z' {
        (byte.to_int() + 32).to_byte()
      } else {
        byte
      },
    )
  }
  @utf8.decode(Bytes::from_array(out)) catch {
    _ => ""
  }
}

///|
fn uri_text(value : BytesView) -> String {
  @utf8.decode(value) catch {
    _ => ""
  }
}

///|
fn validate_uri_component(
  bytes : BytesView,
  offset : Int,
  allow_slash : Bool,
  allow_question : Bool,
) -> Result[Unit, UriError] {
  let mut index = 0
  while index < bytes.length() {
    let byte = bytes[index]
    if byte == b'%' {
      if index + 2 >= bytes.length() ||
        !uri_is_hex(bytes[index + 1]) ||
        !uri_is_hex(bytes[index + 2]) {
        return Err(InvalidPercentEncoding(offset=offset + index))
      }
      index += 3
      continue
    }
    if !uri_is_unreserved(byte) &&
      !uri_is_sub_delim(byte) &&
      byte != b':' &&
      byte != b'@' &&
      !(allow_slash && byte == b'/') &&
      !(allow_question && byte == b'?') {
      return Err(InvalidCharacter(offset=offset + index))
    }
    index += 1
  }
  Ok(())
}

///|
fn parse_port(bytes : BytesView) -> Result[Int?, AuthorityError] {
  if bytes.is_empty() {
    return Err(InvalidPort)
  }
  let mut port = 0
  for byte in bytes {
    if !uri_is_digit(byte) {
      return Err(InvalidPort)
    }
    let digit = byte.to_int() - 48
    if port > (65535 - digit) / 10 {
      return Err(InvalidPort)
    }
    port = port * 10 + digit
  }
  Ok(Some(port))
}

///|
fn validate_reg_name(bytes : BytesView) -> Result[Unit, AuthorityError] {
  let mut index = 0
  while index < bytes.length() {
    let byte = bytes[index]
    if byte == b'%' {
      if index + 2 >= bytes.length() ||
        !uri_is_hex(bytes[index + 1]) ||
        !uri_is_hex(bytes[index + 2]) {
        return Err(InvalidHost)
      }
      index += 3
      continue
    }
    if !uri_is_unreserved(byte) && !uri_is_sub_delim(byte) {
      return Err(InvalidHost)
    }
    index += 1
  }
  Ok(())
}

///|
fn uri_valid_ipv4_octet(input : BytesView) -> Bool {
  if input.is_empty() || input.length() > 3 {
    return false
  }
  if input.length() > 1 && input[0] == b'0' {
    return false
  }
  let mut value = 0
  for byte in input {
    if !uri_is_digit(byte) {
      return false
    }
    value = value * 10 + byte.to_int() - 48
  }
  value <= 255
}

///|
fn uri_valid_ipv4(input : BytesView) -> Bool {
  let mut start = 0
  let mut octets = 0
  for index in 0..<=input.length() {
    if index == input.length() || input[index] == b'.' {
      if !uri_valid_ipv4_octet(input[start:index]) {
        return false
      }
      octets += 1
      start = index + 1
    }
  }
  octets == 4
}

///|
fn uri_valid_ipv6_group(input : BytesView) -> Bool {
  if input.is_empty() || input.length() > 4 {
    return false
  }
  for byte in input {
    if !uri_is_hex(byte) {
      return false
    }
  }
  true
}

///|
fn uri_valid_ipv6(input : BytesView) -> Bool {
  if input.is_empty() {
    return false
  }
  let mut index = 0
  let mut groups = 0
  let mut compressed = false
  if input[0] == b':' {
    if input.length() < 2 || input[1] != b':' {
      return false
    }
    compressed = true
    index = 2
    if index == input.length() {
      return true
    }
  }
  while index < input.length() {
    let start = index
    while index < input.length() && input[index] != b':' {
      index += 1
    }
    if start == index {
      return false
    }
    let group = input[start:index]
    let mut ipv4_tail = false
    for byte in group {
      if byte == b'.' {
        ipv4_tail = true
        break
      }
    }
    if ipv4_tail {
      if index != input.length() || !uri_valid_ipv4(group) {
        return false
      }
      groups += 2
    } else {
      if !uri_valid_ipv6_group(group) {
        return false
      }
      groups += 1
    }
    if groups > 8 {
      return false
    }
    if index == input.length() {
      break
    }
    if index + 1 < input.length() && input[index + 1] == b':' {
      if compressed {
        return false
      }
      compressed = true
      index += 2
      if index == input.length() {
        break
      }
    } else {
      index += 1
      if index == input.length() {
        return false
      }
    }
  }
  if compressed {
    groups < 8
  } else {
    groups == 8
  }
}

///|
/// Validates the RFC 3986 `IPvFuture` form inside an IP-literal.
fn uri_valid_ipvfuture(input : BytesView) -> Bool {
  if input.length() < 4 || (input[0] != b'v' && input[0] != b'V') {
    return false
  }
  let mut dot = -1
  for index in 1..<input.length() {
    if input[index] == b'.' {
      dot = index
      break
    }
    if !uri_is_hex(input[index]) {
      return false
    }
  }
  if dot <= 1 || dot + 1 >= input.length() {
    return false
  }
  for byte in input[dot + 1:] {
    if !uri_is_unreserved(byte) && !uri_is_sub_delim(byte) && byte != b':' {
      return false
    }
  }
  true
}

///|
fn validate_ip_literal(bytes : BytesView) -> Result[Unit, AuthorityError] {
  if !uri_valid_ipv6(bytes) && !uri_valid_ipvfuture(bytes) {
    return Err(InvalidHost)
  }
  Ok(())
}

///|
pub fn Authority::parse(value : String) -> Result[Authority, AuthorityError] {
  let bytes = @utf8.encode(value)
  if bytes.is_empty() {
    return Err(EmptyAuthority)
  }
  for byte in bytes {
    if byte <= b' ' ||
      byte >= b'\x7f' ||
      byte == b'/' ||
      byte == b'?' ||
      byte == b'#' ||
      byte == b'\\' {
      return Err(InvalidAuthority)
    }
  }
  let mut at = -1
  for index in 0..<bytes.length() {
    if bytes[index] == b'@' {
      if at >= 0 {
        return Err(InvalidAuthority)
      }
      at = index
    }
  }
  let userinfo = if at >= 0 {
    if at == 0 {
      return Err(InvalidAuthority)
    }
    match validate_uri_component(bytes[:at], 0, false, false) {
      Ok(_) => ()
      Err(_) => return Err(InvalidAuthority)
    }
    Some(uri_text(bytes[:at]))
  } else {
    None
  }
  let host_start = at + 1
  if host_start >= bytes.length() {
    return Err(InvalidHost)
  }
  let mut host_end = bytes.length()
  let mut port : Int? = None
  let mut ip_literal = false
  if bytes[host_start] == b'[' {
    ip_literal = true
    let mut closing = -1
    for index in (host_start + 1)..<bytes.length() {
      if bytes[index] == b']' {
        closing = index
        break
      }
    }
    if closing < 0 {
      return Err(InvalidHost)
    }
    host_end = closing
    match validate_ip_literal(bytes[host_start + 1:host_end]) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    if closing + 1 < bytes.length() {
      if bytes[closing + 1] != b':' {
        return Err(InvalidAuthority)
      }
      port = match parse_port(bytes[closing + 2:]) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
    }
  } else {
    let mut colon = -1
    for index in host_start..<bytes.length() {
      if bytes[index] == b':' {
        if colon >= 0 {
          return Err(InvalidHost)
        }
        colon = index
      }
    }
    if colon >= 0 {
      host_end = colon
      port = match parse_port(bytes[colon + 1:]) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
    }
    if host_end == host_start {
      return Err(InvalidHost)
    }
    match validate_reg_name(bytes[host_start:host_end]) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  let host_bytes = if ip_literal {
    bytes[host_start + 1:host_end]
  } else {
    bytes[host_start:host_end]
  }
  Ok({ value, userinfo, host: ascii_lower(host_bytes), port, ip_literal, })
}

///|
pub fn Authority::parse_endpoint(
  value : String,
) -> Result[Authority, AuthorityError] {
  match Authority::parse(value) {
    Ok(authority) if authority.userinfo is None => Ok(authority)
    Ok(_) => Err(InvalidAuthority)
    Err(error) => Err(error)
  }
}

///|
fn find_byte(bytes : BytesView, target : Byte, start : Int) -> Int {
  for index in start..<bytes.length() {
    if bytes[index] == target {
      return index
    }
  }
  -1
}

///|
fn earliest_delimiter(bytes : BytesView, start : Int) -> Int {
  let mut end = bytes.length()
  for delimiter in [b'/', b'?', b'#'] {
    let index = find_byte(bytes, delimiter, start)
    if index >= 0 && index < end {
      end = index
    }
  }
  end
}

///|
fn valid_scheme(bytes : BytesView) -> Bool {
  if bytes.is_empty() || !uri_is_alpha(bytes[0]) {
    return false
  }
  for byte in bytes[1:] {
    if !uri_is_alpha(byte) &&
      !uri_is_digit(byte) &&
      byte != b'+' &&
      byte != b'-' &&
      byte != b'.' {
      return false
    }
  }
  true
}

///|
fn split_path_query_fragment(
  bytes : BytesView,
  start : Int,
) -> Result[(String, String?, String?), UriError] {
  let query_mark = find_byte(bytes, b'?', start)
  let fragment_mark = find_byte(bytes, b'#', start)
  if query_mark >= 0 && fragment_mark >= 0 && fragment_mark < query_mark {
    return Err(InvalidCharacter(offset=query_mark))
  }
  let path_end = if query_mark >= 0 {
    query_mark
  } else if fragment_mark >= 0 {
    fragment_mark
  } else {
    bytes.length()
  }
  match validate_uri_component(bytes[start:path_end], start, true, false) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let query = if query_mark >= 0 {
    let end = if fragment_mark >= 0 { fragment_mark } else { bytes.length() }
    match
      validate_uri_component(
        bytes[query_mark + 1:end],
        query_mark + 1,
        true,
        true,
      ) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    Some(uri_text(bytes[query_mark + 1:end]))
  } else {
    None
  }
  let fragment = if fragment_mark >= 0 {
    match
      validate_uri_component(
        bytes[fragment_mark + 1:],
        fragment_mark + 1,
        true,
        true,
      ) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    Some(uri_text(bytes[fragment_mark + 1:]))
  } else {
    None
  }
  Ok((uri_text(bytes[start:path_end]), query, fragment))
}

///|
pub fn Uri::parse(value : String) -> Result[Uri, UriError] {
  let bytes = @utf8.encode(value)
  if bytes.is_empty() {
    return Err(EmptyUri)
  }
  for index in 0..<bytes.length() {
    let byte = bytes[index]
    if byte <= b' ' || byte >= b'\x7f' || byte == b'\\' {
      return Err(InvalidCharacter(offset=index))
    }
  }
  if bytes == b"*" {
    return Ok({
      value,
      scheme: None,
      authority: None,
      path: "*",
      query: None,
      fragment: None,
      form: AsteriskForm,
    })
  }
  if bytes[0] == b'/' {
    let (path, query, fragment) = match split_path_query_fragment(bytes, 0) {
      Ok(parts) => parts
      Err(error) => return Err(error)
    }
    return Ok({
      value,
      scheme: None,
      authority: None,
      path,
      query,
      fragment,
      form: OriginForm,
    })
  }
  let colon = find_byte(bytes, b':', 0)
  let first_delimiter = earliest_delimiter(bytes, 0)
  if colon > 0 && colon < first_delimiter {
    if !valid_scheme(bytes[:colon]) {
      return Err(InvalidScheme)
    }
    let scheme = ascii_lower(bytes[:colon])
    let mut path_start = colon + 1
    let mut authority : Authority? = None
    if path_start + 1 < bytes.length() &&
      bytes[path_start] == b'/' &&
      bytes[path_start + 1] == b'/' {
      let authority_start = path_start + 2
      let authority_end = earliest_delimiter(bytes, authority_start)
      let parsed = match
        Authority::parse(uri_text(bytes[authority_start:authority_end])) {
        Ok(value) => value
        Err(error) => return Err(InvalidAuthority(error))
      }
      authority = Some(parsed)
      path_start = authority_end
    }
    let (path, query, fragment) = match
      split_path_query_fragment(bytes, path_start) {
      Ok(parts) => parts
      Err(error) => return Err(error)
    }
    return Ok({
      value,
      scheme: Some(scheme),
      authority,
      path,
      query,
      fragment,
      form: AbsoluteForm,
    })
  }
  let authority = match Authority::parse(value) {
    Ok(value) => value
    Err(error) => return Err(InvalidAuthority(error))
  }
  Ok({
    value,
    scheme: None,
    authority: Some(authority),
    path: "",
    query: None,
    fragment: None,
    form: AuthorityForm,
  })
}

///|
/// Parses an HTTP request-target with the method available to disambiguate
/// CONNECT authority-form from an absolute URI scheme.
pub fn Uri::parse_request_target(
  value : String,
  http_method : Method,
) -> Result[Uri, UriError] {
  if http_method == Connect {
    let authority = match Authority::parse_endpoint(value) {
      Ok(value) => value
      Err(error) => return Err(InvalidAuthority(error))
    }
    if authority.port is None {
      return Err(InvalidRequestTarget)
    }
    return Ok({
      value,
      scheme: None,
      authority: Some(authority),
      path: "",
      query: None,
      fragment: None,
      form: AuthorityForm,
    })
  }
  let uri = match Uri::parse(value) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match uri.validate_request_target(http_method) {
    Ok(_) => Ok(uri)
    Err(error) => Err(error)
  }
}

///|
pub fn Uri::validate(self : Uri) -> Result[Unit, UriError] {
  let reparsed = match self.form {
    AuthorityForm => Uri::parse_request_target(self.value, Connect)
    AsteriskForm | OriginForm | AbsoluteForm => Uri::parse(self.value)
  }
  match reparsed {
    Ok(parsed) if parsed == self => Ok(())
    Ok(_) => Err(InvalidUri("URI components do not match its serialized value"))
    Err(error) => Err(error)
  }
}

///|
pub fn Uri::validate_request_target(
  self : Uri,
  http_method : Method,
) -> Result[Unit, UriError] {
  match self.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if self.fragment is Some(_) {
    return Err(FragmentNotAllowed)
  }
  if self.authority is Some(authority) && authority.userinfo is Some(_) {
    return Err(UserinfoNotAllowed)
  }
  if self.form == AbsoluteForm &&
    (self.scheme == Some("http") || self.scheme == Some("https")) &&
    self.authority is None {
    return Err(InvalidRequestTarget)
  }
  match (http_method, self.form) {
    (Connect, AuthorityForm) => Ok(())
    (Connect, _) => Err(InvalidRequestTarget)
    (Options, AsteriskForm) => Ok(())
    (_, OriginForm | AbsoluteForm) => Ok(())
    _ => Err(InvalidRequestTarget)
  }
}

///|
pub fn Uri::origin_form(self : Uri) -> Result[String, UriError] {
  match self.form {
    OriginForm => Ok(self.value)
    AbsoluteForm => {
      let path = if self.path == "" { "/" } else { self.path }
      Ok(
        match self.query {
          Some(query) => path + "?" + query
          None => path
        },
      )
    }
    _ => Err(InvalidRequestTarget)
  }
}

///|
pub fn Uri::without_fragment(self : Uri) -> Result[Uri, UriError] {
  if self.fragment is None {
    return Ok(self)
  }
  let bytes = @utf8.encode(self.value)
  let marker = find_byte(bytes, b'#', 0)
  if marker < 0 {
    return Err(InvalidUri("URI fragment state is inconsistent"))
  }
  Uri::parse(uri_text(bytes[:marker]))
}

///|
fn uri_last_slash(bytes : BytesView) -> Int {
  let mut result = -1
  for index in 0..<bytes.length() {
    if bytes[index] == b'/' {
      result = index
    }
  }
  result
}

///|
fn remove_dot_segments(path : String) -> String {
  let absolute = path.has_prefix("/")
  let trailing = path.has_suffix("/") ||
    path.has_suffix("/.") ||
    path.has_suffix("/..")
  let segments : Array[String] = []
  for view in path.split("/") {
    let segment = view.to_owned()
    if segment == "." {
      continue
    }
    if segment == ".." {
      if !segments.is_empty() && segments[segments.length() - 1] != "" {
        ignore(segments.pop())
      }
      continue
    }
    segments.push(segment)
  }
  if trailing && (segments.is_empty() || segments[segments.length() - 1] != "") {
    segments.push("")
  }
  let mut normalized = segments.join("/")
  if absolute && !normalized.has_prefix("/") {
    normalized = "/" + normalized
  }
  if absolute && normalized == "" {
    "/"
  } else {
    normalized
  }
}

///|
fn uri_absolute_prefix(base : Uri) -> Result[String, UriError] {
  let scheme = match base.scheme {
    Some(value) => value
    None => return Err(InvalidRequestTarget)
  }
  let authority = match base.authority {
    Some(value) if value.userinfo is None => value
    Some(_) => return Err(UserinfoNotAllowed)
    None => return Err(InvalidRequestTarget)
  }
  Ok(scheme + "://" + authority.value)
}

///|
/// Resolves an HTTP Location reference against an absolute base URI. The
/// fragment is removed because it is not part of an HTTP request target.
pub fn Uri::resolve_reference(
  base : Uri,
  reference : String,
) -> Result[Uri, UriError] {
  if base.form != AbsoluteForm || base.fragment is Some(_) {
    return Err(InvalidRequestTarget)
  }
  let prefix = match uri_absolute_prefix(base) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let reference_bytes = @utf8.encode(reference)
  for index in 0..<reference_bytes.length() {
    let byte = reference_bytes[index]
    if byte <= b' ' || byte >= b'\x7f' || byte == b'\\' {
      return Err(InvalidCharacter(offset=index))
    }
  }
  let fragment = find_byte(reference_bytes, b'#', 0)
  let reference_bytes = if fragment >= 0 {
    reference_bytes[:fragment]
  } else {
    reference_bytes[:]
  }
  let reference_text = uri_text(reference_bytes)
  if !reference_bytes.is_empty() {
    let colon = find_byte(reference_bytes, b':', 0)
    let delimiter = earliest_delimiter(reference_bytes, 0)
    if colon > 0 && colon < delimiter {
      let absolute = match Uri::parse(reference_text) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let absolute = match absolute.without_fragment() {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if absolute.form != AbsoluteForm || absolute.authority is None {
        return Err(InvalidRequestTarget)
      }
      if absolute.authority is Some(value) && value.userinfo is Some(_) {
        return Err(UserinfoNotAllowed)
      }
      return Ok(absolute)
    }
  }
  if reference_text.has_prefix("//") {
    let scheme = match base.scheme {
      Some(value) => value
      None => return Err(InvalidRequestTarget)
    }
    let result = match Uri::parse(scheme + ":" + reference_text) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if result.authority is Some(value) && value.userinfo is Some(_) {
      return Err(UserinfoNotAllowed)
    }
    return Ok(result)
  }
  if reference_text.has_prefix("/") {
    let question = find_byte(reference_bytes, b'?', 0)
    let path = if question >= 0 {
      uri_text(reference_bytes[:question])
    } else {
      reference_text
    }
    let suffix = if question >= 0 {
      uri_text(reference_bytes[question:])
    } else {
      ""
    }
    return Uri::parse(prefix + remove_dot_segments(path) + suffix)
  }
  let base_path = if base.path == "" { "/" } else { base.path }
  if reference_bytes.is_empty() {
    let suffix = match base.query {
      Some(value) => "?" + value
      None => ""
    }
    return Uri::parse(prefix + base_path + suffix)
  }
  if reference_text.has_prefix("?") {
    return Uri::parse(prefix + base_path + reference_text)
  }
  let question = find_byte(reference_bytes, b'?', 0)
  let relative_path = if question >= 0 {
    uri_text(reference_bytes[:question])
  } else {
    reference_text
  }
  let query = if question >= 0 {
    uri_text(reference_bytes[question:])
  } else {
    ""
  }
  let base_bytes = @utf8.encode(base_path)
  let slash = uri_last_slash(base_bytes)
  let directory = if slash >= 0 {
    uri_text(base_bytes[:slash + 1])
  } else {
    "/"
  }
  Uri::parse(prefix + remove_dot_segments(directory + relative_path) + query)
}
