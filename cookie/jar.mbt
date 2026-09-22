///|
pub struct CookieJar {
  mut cookies : Array[Cookie]
  limits : CookieLimits
  mut enabled : Bool
  mut next_order : Int64
}

///|
pub fn CookieJar::new(
  enabled? : Bool = false,
  limits? : CookieLimits = CookieLimits::defaults(),
) -> Result[CookieJar, CookieError] {
  match limits.validate() {
    Ok(_) => Ok({ cookies: [], limits, enabled, next_order: 0L, })
    Err(error) => Err(error)
  }
}

///|
pub fn CookieJar::is_enabled(self : CookieJar) -> Bool {
  self.enabled
}

///|
pub fn CookieJar::set_enabled(self : CookieJar, enabled : Bool) -> Unit {
  self.enabled = enabled
}

///|
fn cookie_ascii_lower_text(value : String) -> String {
  let bytes = @utf8.encode(value)
  let lowered = FixedArray::make(bytes.length(), b'0')
  for index in 0..<bytes.length() {
    lowered[index] = cookie_ascii_lower_byte(bytes[index])
  }
  @utf8.decode(lowered.unsafe_reinterpret_as_bytes()) catch {
    _ => ""
  }
}

///|
fn cookie_request_parts(
  uri : @types.Uri,
) -> Result[(String, Bool, Bytes), CookieError] {
  if uri.form != AbsoluteForm {
    return Err(InvalidCookieRequestUri)
  }
  let authority = match uri.authority {
    Some(value) if value.userinfo is None => value
    _ => return Err(InvalidCookieRequestUri)
  }
  let secure = match uri.scheme {
    Some("https") => true
    Some("http") => false
    _ => return Err(InvalidCookieRequestUri)
  }
  let raw_host = authority.host
  let host = if psl_is_ip_literal(raw_host) {
    cookie_ascii_lower_text(raw_host)
  } else {
    match normalize_domain(raw_host) {
      Ok(value) => value
      Err(_) => return Err(InvalidCookieRequestUri)
    }
  }
  if host.is_empty() {
    return Err(InvalidCookieRequestUri)
  }
  let path = if uri.path.is_empty() { b"/" } else { @utf8.encode(uri.path) }
  Ok((host, secure, path))
}

///|
fn cookie_domain_matches(host : String, domain : String) -> Bool {
  host == domain || (!psl_is_ip_literal(host) && host.has_suffix("." + domain))
}

///|
fn cookie_path_matches(
  request_path : BytesView,
  cookie_path : BytesView,
) -> Bool {
  if request_path == cookie_path {
    return true
  }
  if request_path.length() < cookie_path.length() ||
    request_path[:cookie_path.length()] != cookie_path {
    return false
  }
  cookie_path.has_suffix(b"/") ||
  (
    request_path.length() > cookie_path.length() &&
    request_path[cookie_path.length()] == b'/'
  )
}

///|
fn cookie_default_path(request_path : BytesView) -> Bytes {
  if request_path.is_empty() || request_path[0] != b'/' {
    return b"/"
  }
  let mut last_slash = 0
  for index in 1..<request_path.length() {
    if request_path[index] == b'/' {
      last_slash = index
    }
  }
  if last_slash == 0 {
    b"/"
  } else {
    request_path[:last_slash].to_owned()
  }
}

///|
fn cookie_safe_method(http_method : @types.Method) -> Bool {
  http_method == Get ||
  http_method == Head ||
  http_method == Options ||
  http_method == Trace
}

///|
fn cookie_saturating_add(value : Int64, delta : Int64) -> Int64 {
  if value > 9223372036854775807L - delta {
    9223372036854775807L
  } else {
    value + delta
  }
}

///|
fn CookieJar::tick(self : CookieJar) -> Int64 {
  let value = self.next_order
  if self.next_order < 9223372036854775807L {
    self.next_order += 1L
  }
  value
}

///|
fn CookieJar::remove_expired(self : CookieJar, now_seconds : Int64) -> Unit {
  let retained : Array[Cookie] = []
  for cookie in self.cookies {
    if cookie.expiry_seconds is Some(expiry) && expiry <= now_seconds {
      continue
    }
    retained.push(cookie)
  }
  self.cookies = retained
}

///|
fn CookieJar::identity_index(
  self : CookieJar,
  name : Bytes,
  domain : String,
  host_only : Bool,
  path : Bytes,
) -> Int {
  for index, cookie in self.cookies {
    if cookie.name == name &&
      cookie.domain == domain &&
      cookie.host_only == host_only &&
      cookie.path == path {
      return index
    }
  }
  -1
}

///|
fn CookieJar::oldest_in_domain(
  self : CookieJar,
  domain : String,
  insecure_only : Bool,
) -> Int {
  let mut selected = -1
  for index, cookie in self.cookies {
    if cookie.domain != domain || (insecure_only && cookie.secure) {
      continue
    }
    if selected < 0 ||
      cookie.last_access_order < self.cookies[selected].last_access_order {
      selected = index
    }
  }
  selected
}

///|
fn CookieJar::oldest(self : CookieJar) -> Int {
  let mut selected = -1
  for index, cookie in self.cookies {
    if selected < 0 ||
      cookie.last_access_order < self.cookies[selected].last_access_order {
      selected = index
    }
  }
  selected
}

///|
fn CookieJar::enforce_limits(self : CookieJar, domain : String) -> Unit {
  let mut domain_count = 0
  for cookie in self.cookies {
    if cookie.domain == domain {
      domain_count += 1
    }
  }
  while domain_count > self.limits.max_cookies_per_domain {
    let mut index = self.oldest_in_domain(domain, true)
    if index < 0 {
      index = self.oldest_in_domain(domain, false)
    }
    if index < 0 {
      break
    }
    self.cookies.remove(index) |> ignore
    domain_count -= 1
  }
  while self.cookies.length() > self.limits.max_cookies {
    let index = self.oldest()
    if index < 0 {
      break
    }
    self.cookies.remove(index) |> ignore
  }
}

///|
fn cookie_prefix_rejection(cookie : ParsedSetCookie, host_only : Bool) -> Bool {
  let secure_prefix = cookie_ascii_prefix_fold(cookie.name, b"__secure-")
  let host_prefix = cookie_ascii_prefix_fold(cookie.name, b"__host-")
  let disguised_prefix = cookie.name.is_empty() &&
    (
      cookie_ascii_prefix_fold(cookie.value, b"__secure-") ||
      cookie_ascii_prefix_fold(cookie.value, b"__host-")
    )
  disguised_prefix ||
  (secure_prefix && !cookie.secure) ||
  (
    host_prefix &&
    (
      !cookie.secure ||
      !host_only ||
      !cookie.explicit_path ||
      cookie.path != Some(b"/")
    )
  )
}

///|
fn CookieJar::secure_overlay_exists(
  self : CookieJar,
  incoming : ParsedSetCookie,
  domain : String,
  path : Bytes,
  secure_origin : Bool,
) -> Bool {
  if incoming.secure || secure_origin {
    return false
  }
  for existing in self.cookies {
    if existing.name == incoming.name &&
      existing.secure &&
      (
        cookie_domain_matches(existing.domain, domain) ||
        cookie_domain_matches(domain, existing.domain)
      ) &&
      cookie_path_matches(path, existing.path) {
      return true
    }
  }
  false
}

///|
pub fn CookieJar::store(
  self : CookieJar,
  header : @types.HeaderValue,
  request_uri : @types.Uri,
  now_seconds : Int64,
  context? : CookieContext = CookieContext::http(Get),
) -> Result[CookieStoreOutcome, CookieError] {
  if !self.enabled {
    return Ok(CookieIgnored(CookieJarDisabled))
  }
  let (request_host, secure_origin, request_path) = match
    cookie_request_parts(request_uri) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let parsed = match parse_set_cookie(header, self.limits) {
    Ok(value) => value
    Err(reason) => return Ok(CookieIgnored(reason))
  }
  if parsed.partitioned {
    return Ok(CookieIgnored(PartitionedCookieUnsupported))
  }
  if parsed.secure && !secure_origin {
    return Ok(CookieIgnored(SecureCookieFromInsecureOrigin))
  }
  if parsed.http_only && context.api == NonHttpCookieApi {
    return Ok(CookieIgnored(HttpOnlyFromNonHttpApi))
  }
  if parsed.same_site == SameSiteNone && !parsed.secure {
    return Ok(CookieIgnored(SameSiteNoneWithoutSecure))
  }
  if parsed.same_site != SameSiteNone &&
    !context.same_site &&
    !context.top_level_navigation {
    return Ok(CookieIgnored(SameSiteContextRejected))
  }
  let mut host_only = parsed.domain is None
  let domain = match parsed.domain {
    None => request_host
    Some(raw_domain) => {
      if psl_is_ip_literal(request_host) {
        return Ok(CookieIgnored(InvalidCookieDomain))
      }
      let normalized = match normalize_domain(raw_domain) {
        Ok(value) => value
        Err(_) => return Ok(CookieIgnored(InvalidCookieDomain))
      }
      let public = match is_public_suffix(normalized) {
        Ok(value) => value
        Err(_) => return Ok(CookieIgnored(InvalidCookieDomain))
      }
      if public {
        if normalized == request_host {
          host_only = true
          request_host
        } else {
          return Ok(CookieIgnored(CookiePublicSuffix))
        }
      } else if !cookie_domain_matches(request_host, normalized) {
        return Ok(CookieIgnored(CookieDomainMismatch))
      } else {
        normalized
      }
    }
  }
  let path = match parsed.path {
    Some(value) => value
    None => cookie_default_path(request_path)
  }
  if cookie_prefix_rejection(parsed, host_only) {
    return Ok(CookieIgnored(CookiePrefixViolation))
  }
  if self.secure_overlay_exists(parsed, domain, path, secure_origin) {
    return Ok(CookieIgnored(SecureCookieOverlay))
  }
  self.remove_expired(now_seconds)
  let existing_index = self.identity_index(parsed.name, domain, host_only, path)
  if existing_index >= 0 &&
    context.api == NonHttpCookieApi &&
    self.cookies[existing_index].http_only {
    return Ok(CookieIgnored(HttpOnlyFromNonHttpApi))
  }
  let lifetime_cap = cookie_saturating_add(
    now_seconds,
    self.limits.max_lifetime_seconds,
  )
  let expiry = match parsed.max_age_seconds {
    Some(seconds) => Some(cookie_saturating_add(now_seconds, seconds))
    None =>
      match parsed.expires_seconds {
        Some(seconds) => Some(seconds.min(lifetime_cap))
        None => None
      }
  }
  if expiry is Some(value) && value <= now_seconds {
    if existing_index >= 0 {
      self.cookies.remove(existing_index) |> ignore
    }
    return Ok(CookieDeleted)
  }
  let creation_order = if existing_index >= 0 {
    self.cookies[existing_index].creation_order
  } else {
    self.tick()
  }
  let replaced = existing_index >= 0
  if replaced {
    self.cookies.remove(existing_index) |> ignore
  }
  let access_order = self.tick()
  self.cookies.push({
    name: parsed.name,
    value: parsed.value,
    domain,
    path,
    expiry_seconds: expiry,
    persistent: expiry is Some(_),
    host_only,
    secure: parsed.secure,
    http_only: parsed.http_only,
    same_site: parsed.same_site,
    creation_order,
    last_access_order: access_order,
  })
  self.enforce_limits(domain)
  Ok(if replaced { CookieReplaced } else { CookieStored })
}

///|
pub fn CookieJar::store_string(
  self : CookieJar,
  header : String,
  request_uri : @types.Uri,
  now_seconds : Int64,
  context? : CookieContext = CookieContext::http(Get),
) -> Result[CookieStoreOutcome, CookieError] {
  let value = match @types.HeaderValue::from_string(header) {
    Ok(value) => value
    Err(_) => return Ok(CookieIgnored(MalformedSetCookie))
  }
  self.store(value, request_uri, now_seconds, context~)
}

///|
fn cookie_retrieval_allowed(
  cookie : Cookie,
  request_host : String,
  secure_origin : Bool,
  request_path : BytesView,
  context : CookieContext,
) -> Bool {
  let domain_allowed = if cookie.host_only {
    cookie.domain == request_host
  } else {
    cookie_domain_matches(request_host, cookie.domain) &&
    is_public_suffix(cookie.domain) == Ok(false)
  }
  if !domain_allowed ||
    !cookie_path_matches(request_path, cookie.path) ||
    (cookie.secure && !secure_origin) ||
    (cookie.http_only && context.api == NonHttpCookieApi) {
    return false
  }
  if context.same_site || cookie.same_site == SameSiteNone {
    return true
  }
  (cookie.same_site == SameSiteLax || cookie.same_site == SameSiteDefault) &&
  context.api == HttpCookieApi &&
  context.top_level_navigation &&
  cookie_safe_method(context.http_method)
}

///|
pub fn CookieJar::cookie_header(
  self : CookieJar,
  request_uri : @types.Uri,
  now_seconds : Int64,
  context? : CookieContext = CookieContext::http(Get),
) -> Result[@types.HeaderValue?, CookieError] {
  if !self.enabled {
    return Ok(None)
  }
  let (request_host, secure_origin, request_path) = match
    cookie_request_parts(request_uri) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  self.remove_expired(now_seconds)
  let selected : Array[Cookie] = []
  for cookie in self.cookies {
    if cookie_retrieval_allowed(
        cookie, request_host, secure_origin, request_path, context,
      ) {
      selected.push(cookie)
    }
  }
  selected.sort_by(fn(first, second) {
    if first.path.length() != second.path.length() {
      if first.path.length() > second.path.length() {
        -1
      } else {
        1
      }
    } else if first.creation_order < second.creation_order {
      -1
    } else if first.creation_order > second.creation_order {
      1
    } else {
      0
    }
  })
  if selected.is_empty() {
    return Ok(None)
  }
  let output : Array[Byte] = []
  for index, cookie in selected {
    let separator_bytes = if index == 0 { 0 } else { 2 }
    let equals_bytes = if cookie.name.is_empty() { 0 } else { 1 }
    let addition = separator_bytes +
      cookie.name.length() +
      equals_bytes +
      cookie.value.length()
    if output.length() > self.limits.max_cookie_header_bytes - addition {
      return Err(CookieHeaderLimitExceeded)
    }
    if index > 0 {
      output.push(b';')
      output.push(b' ')
    }
    for byte in cookie.name {
      output.push(byte)
    }
    if !cookie.name.is_empty() {
      output.push(b'=')
    }
    for byte in cookie.value {
      output.push(byte)
    }
    cookie.last_access_order = self.tick()
  }
  match @types.HeaderValue::from_bytes(Bytes::from_array(output)) {
    Ok(value) => Ok(Some(value))
    Err(_) => Err(CookieHeaderLimitExceeded)
  }
}

///|
pub fn CookieJar::size(self : CookieJar, now_seconds? : Int64 = 0L) -> Int {
  self.remove_expired(now_seconds)
  self.cookies.length()
}

///|
pub fn CookieJar::clear(self : CookieJar) -> Unit {
  self.cookies.clear()
}

///|
pub fn CookieJar::clear_session(self : CookieJar) -> Unit {
  let retained : Array[Cookie] = []
  for cookie in self.cookies {
    if cookie.persistent {
      retained.push(cookie)
    }
  }
  self.cookies = retained
}
