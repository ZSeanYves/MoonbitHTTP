///|
pub struct HttpCache {
  entries : Array[CacheEntry]
  config : CacheConfig
  mut total_bytes : Int32
  mut next_order : Int64
}

///|
struct CacheEntry {
  key : String
  vary : Array[String]
  vary_signature : String
  response : @types.Response[Unit]
  body : Bytes
  stored_at : Int64
  initial_age : Int64
  freshness_lifetime : Int64
  stale_while_revalidate : Int64
  stale_if_error : Int64?
  no_cache : Bool
  must_revalidate : Bool
  etag : String?
  last_modified : String?
  size : Int32
  mut last_used : Int64
  order : Int64
}

///|
pub fn HttpCache::new(
  config~ : CacheConfig = CacheConfig::defaults(),
) -> Result[HttpCache, CacheError] {
  match config.validate() {
    Ok(_) => Ok({ entries: [], config, total_bytes: 0, next_order: 0L, })
    Err(error) => Err(error)
  }
}

///|
pub fn HttpCache::len(self : HttpCache) -> Int32 {
  self.entries.length()
}

///|
pub fn HttpCache::total_bytes(self : HttpCache) -> Int32 {
  self.total_bytes
}

///|
pub fn HttpCache::clear(self : HttpCache) -> Unit {
  self.entries.clear()
  self.total_bytes = 0
}

///|
fn HttpCache::cache_tick(self : HttpCache) -> Int64 {
  let value = self.next_order
  if self.next_order < 0x7fffffffffffffffL {
    self.next_order += 1L
  }
  value
}

///|
fn cache_add_saturating(left : Int64, right : Int64) -> Int64 {
  if right > 0L && left > 0x7fffffffffffffffL - right {
    0x7fffffffffffffffL
  } else if right < 0L && left < -0x7fffffffffffffffL - 1L - right {
    -0x7fffffffffffffffL - 1L
  } else {
    left + right
  }
}

///|
fn cache_clone_headers(source : @types.HeaderMap) -> @types.HeaderMap {
  let output = @types.HeaderMap::new()
  for field in source.fields() {
    output.append(field.name, field.value)
  }
  output
}

///|
fn cache_clone_response(
  source : @types.Response[Unit],
) -> @types.Response[Unit] {
  {
    status: source.status,
    version: source.version,
    headers: cache_clone_headers(source.headers),
    body: (),
  }
}

///|
fn cache_base_key(request : @types.Request[Unit]) -> Result[String, CacheError] {
  match request.http_method {
    Get | Head => ()
    _ => return Err(InvalidRequest)
  }
  match request.uri.validate() {
    Ok(_) => ()
    Err(_) => return Err(InvalidRequest)
  }
  if request.uri.form != AbsoluteForm || request.uri.fragment is Some(_) {
    return Err(InvalidRequest)
  }
  let scheme = match request.uri.scheme {
    Some(value) if value == "http" || value == "https" => value
    _ => return Err(InvalidRequest)
  }
  let authority = match request.uri.authority {
    Some(value) if value.userinfo is None => value
    _ => return Err(InvalidRequest)
  }
  let port = match authority.port {
    Some(value) => value
    None => if scheme == "https" { 443 } else { 80 }
  }
  let path = if request.uri.path.is_empty() { "/" } else { request.uri.path }
  let query = match request.uri.query {
    Some(value) => "?" + value
    None => ""
  }
  let rendered_host = if authority.ip_literal {
    "[" + authority.host + "]"
  } else {
    authority.host
  }
  Ok(scheme + "://" + rendered_host + ":" + port.to_string() + path + query)
}

///|
fn cache_hex(value : BytesView) -> String {
  let digits = "0123456789abcdef"
  let output = StringBuilder()
  for byte in value {
    let number = byte.to_int()
    output.write_char(digits.get_char(number >> 4).unwrap())
    output.write_char(digits.get_char(number & 0x0f).unwrap())
  }
  output.to_string()
}

///|
fn cache_vary_signature(
  headers : @types.HeaderMap,
  vary : Array[String],
) -> Result[String, CacheError] {
  let output = StringBuilder()
  for name in vary {
    let parsed = match @types.HeaderName::parse(name) {
      Ok(value) => value
      Err(_) => return Err(InvalidVary)
    }
    output.write_string(name)
    output.write_char('=')
    let values = headers.get_all(parsed)
    output.write_string(values.length().to_string())
    output.write_char(':')
    for value in values {
      let encoded = cache_hex(value.bytes)
      output.write_string(encoded.length().to_string())
      output.write_char(':')
      output.write_string(encoded)
    }
    output.write_char(';')
  }
  Ok(output.to_string())
}

///|
fn cache_header_text(headers : @types.HeaderMap, name : String) -> String? {
  match headers.get_string(name) {
    Some(value) => Some(value.to_string_lossy().trim().to_owned())
    None => None
  }
}

///|
fn cache_parse_date(
  headers : @types.HeaderMap,
  name : String,
  now_seconds : Int64,
) -> Result[Int64?, CacheError] {
  match cache_header_text(headers, name) {
    None => Ok(None)
    Some(value) =>
      match @types.HttpDate::parse(value, now_seconds=Some(now_seconds)) {
        Ok(date) => Ok(Some(date.unix_seconds()))
        Err(_) => Err(InvalidDate)
      }
  }
}

///|
fn cache_etag_valid(value : String) -> Bool {
  let text = value.trim().to_owned()
  if text.has_prefix("W/") {
    text.length() >= 4 && text[2] == '"' && text.has_suffix("\"")
  } else {
    text.length() >= 2 && text[0] == '"' && text.has_suffix("\"")
  }
}

///|
fn cache_validator(
  headers : @types.HeaderMap,
  name : String,
) -> Result[String?, CacheError] {
  match cache_header_text(headers, name) {
    None => Ok(None)
    Some(value) if cache_etag_valid(value) => Ok(Some(value))
    Some(_) => Err(InvalidValidator)
  }
}

///|
fn cache_status_default_cacheable(status : Int32) -> Bool {
  status == 200 ||
  status == 203 ||
  status == 204 ||
  status == 206 ||
  status == 300 ||
  status == 301 ||
  status == 404 ||
  status == 405 ||
  status == 410 ||
  status == 414 ||
  status == 501
}

///|
fn cache_metadata_size(response : @types.Response[Unit]) -> Int32 {
  let mut total = 0
  for field in response.headers.fields() {
    total += field.name.value.length() + field.value.bytes.length() + 4
  }
  total
}

///|
fn cache_freshness_lifetime(
  response : @types.Response[Unit],
  control : CacheControl,
  shared : Bool,
  date_seconds : Int64,
  now_seconds : Int64,
  allow_heuristic : Bool,
  heuristic_max : Int64,
) -> Result[Int64, CacheError] {
  let explicit = if shared {
    match control.s_maxage {
      Some(value) => Some(value)
      None => control.max_age
    }
  } else {
    control.max_age
  }
  match explicit {
    Some(value) => return Ok(value)
    None => ()
  }
  let expires = match
    cache_parse_date(response.headers, "expires", now_seconds) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match expires {
    Some(value) => return Ok((value - date_seconds).max(0L))
    None => ()
  }
  if allow_heuristic {
    let modified = match
      cache_parse_date(response.headers, "last-modified", now_seconds) {
      Ok(value) => value
      Err(_) => None
    }
    match modified {
      Some(value) if date_seconds > value =>
        return Ok(((date_seconds - value) / 10L).min(heuristic_max))
      _ => ()
    }
  }
  Ok(0L)
}

///|
fn cache_entry_hit(
  entry : CacheEntry,
  request : @types.Request[Unit],
  age : Int64,
  stale : Int64,
  allow_error_fallback : Bool,
) -> CacheHit {
  let headers = cache_clone_headers(entry.response.headers)
  let age_value = @types.HeaderValue::from_string(age.max(0L).to_string()).unwrap()
  match @types.HeaderName::parse("age") {
    Ok(name) => headers.set(name, age_value)
    Err(_) => ()
  }
  let body = if request.http_method == Head { b"" } else { entry.body }
  {
    response: {
      status: entry.response.status,
      version: entry.response.version,
      headers,
      body: (),
    },
    body,
    age_seconds: age.max(0L),
    freshness_lifetime: entry.freshness_lifetime,
    stale_seconds: stale.max(0L),
    stale_if_error: if entry.must_revalidate ||
      entry.no_cache ||
      !allow_error_fallback {
      0L
    } else {
      entry.stale_if_error.unwrap_or(0L)
    },
    stale_if_error_allowed: allow_error_fallback &&
    !entry.must_revalidate &&
    !entry.no_cache &&
    entry.stale_if_error is Some(_),
    etag: entry.etag,
    last_modified: entry.last_modified,
  }
}

///|
fn cache_request_control(
  request : @types.Request[Unit],
  max_directives : Int32,
) -> Result[CacheControl, CacheError] {
  parse_cache_control(request.headers, max_directives~)
}

///|
fn cache_entry_matches(
  entry : CacheEntry,
  key : String,
  request_headers : @types.HeaderMap,
) -> Bool {
  if entry.key != key {
    return false
  }
  match cache_vary_signature(request_headers, entry.vary) {
    Ok(value) => value == entry.vary_signature
    Err(_) => false
  }
}

///|
fn HttpCache::cache_remove_at(self : HttpCache, index : Int32) -> Unit {
  self.total_bytes -= self.entries[index].size
  self.entries.remove(index) |> ignore
}

///|
fn HttpCache::cache_enforce_limits(self : HttpCache) -> Unit {
  while self.entries.length() > self.config.limits.max_entries ||
        self.total_bytes > self.config.limits.max_total_bytes {
    let mut selected = -1
    for index, entry in self.entries {
      if selected < 0 ||
        entry.last_used < self.entries[selected].last_used ||
        (
          entry.last_used == self.entries[selected].last_used &&
          entry.order < self.entries[selected].order
        ) {
        selected = index
      }
    }
    if selected < 0 {
      break
    }
    self.cache_remove_at(selected)
  }
}

///|
/// Stores a complete response body. The caller owns the input headers/body;
/// the cache takes bounded copies and never retains a mutable body producer.
pub fn HttpCache::store(
  self : HttpCache,
  request : @types.Request[Unit],
  response : @types.Response[Unit],
  body : Bytes,
  now_seconds : Int64,
) -> Result[CacheStoreOutcome, CacheError] {
  // This cache owns complete GET representations only. A partial/bodyless
  // response must not replace a full representation under the same URI key.
  if request.http_method == Head ||
    request.headers.get_string("range") is Some(_) ||
    request.headers.get_string("if-range") is Some(_) ||
    response.status == 206 ||
    response.status == 304 ||
    response.headers.get_string("content-range") is Some(_) {
    return Ok(CacheNotStored(NotCacheable("incomplete representation")))
  }
  let key = match cache_base_key(request) {
    Ok(value) => value
    Err(error) => return Ok(CacheNotStored(error))
  }
  let request_control = match
    cache_request_control(request, self.config.limits.max_directives) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if request_control.no_store {
    return Ok(CacheNotStored(NotCacheable("request has no-store")))
  }
  if response.status < 100 || response.status > 999 {
    return Err(InvalidResponse)
  }
  if body.length() > self.config.limits.max_entry_bytes {
    return Ok(CacheNotStored(EntryTooLarge(body.length())))
  }
  if !@types.response_allows_body(request.http_method, response.status) &&
    !body.is_empty() {
    return Err(InvalidResponse)
  }
  match response.headers.content_length() {
    Ok(Some(value)) if value != body.length() => return Err(InvalidResponse)
    Err(_) => return Err(InvalidResponse)
    _ => ()
  }
  let control = match
    parse_cache_control(
      response.headers,
      max_directives=self.config.limits.max_directives,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if control.no_store {
    return Ok(CacheNotStored(NotCacheable("response has no-store")))
  }
  if self.config.shared && control.private {
    return Ok(CacheNotStored(NotCacheable("private response in shared cache")))
  }
  if !self.config.allow_set_cookie &&
    response.headers.get_string("set-cookie") is Some(_) {
    return Ok(
      CacheNotStored(NotCacheable("set-cookie is not cacheable by policy")),
    )
  }
  if request.headers.get_string("authorization") is Some(_) &&
    self.config.shared &&
    !control.public &&
    control.s_maxage is None {
    return Ok(
      CacheNotStored(
        NotCacheable("authorized response lacks shared-cache permission"),
      ),
    )
  }
  let vary = match
    parse_vary(response.headers, max_fields=self.config.limits.max_vary_fields) {
    Ok((true, _)) => return Ok(CacheNotStored(NotCacheable("vary wildcard")))
    Ok((false, value)) => value
    Err(error) => return Err(error)
  }
  let vary_signature = match cache_vary_signature(request.headers, vary) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let date_seconds = match
    cache_parse_date(response.headers, "date", now_seconds) {
    Ok(Some(value)) => value
    Ok(None) => now_seconds
    Err(error) => return Err(error)
  }
  let age_header = match parse_age(response.headers) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let initial_age = age_header.max((now_seconds - date_seconds).max(0L))
  let lifetime = match
    cache_freshness_lifetime(
      response,
      control,
      self.config.shared,
      date_seconds,
      now_seconds,
      self.config.allow_heuristic_freshness,
      self.config.limits.heuristic_max_age_seconds,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !cache_status_default_cacheable(response.status) &&
    control.max_age is None &&
    control.s_maxage is None &&
    response.headers.get_string("expires") is None {
    return Ok(
      CacheNotStored(NotCacheable("status is not cacheable by default")),
    )
  }
  let copied_response = cache_clone_response(response)
  let metadata_size = cache_metadata_size(copied_response)
  if metadata_size > self.config.limits.max_metadata_bytes {
    return Ok(CacheNotStored(EntryTooLarge(metadata_size)))
  }
  let size = body.length() + metadata_size
  if size > self.config.limits.max_entry_bytes {
    return Ok(CacheNotStored(EntryTooLarge(size)))
  }
  let order = self.cache_tick()
  let entry = CacheEntry::{
    key,
    vary,
    vary_signature,
    response: copied_response,
    body,
    stored_at: now_seconds,
    initial_age,
    freshness_lifetime: lifetime,
    stale_while_revalidate: control.stale_while_revalidate.unwrap_or(0L),
    stale_if_error: control.stale_if_error,
    no_cache: control.no_cache,
    must_revalidate: control.must_revalidate || control.proxy_revalidate,
    etag: match cache_validator(response.headers, "etag") {
      Ok(value) => value
      Err(error) => return Err(error)
    },
    last_modified: cache_header_text(response.headers, "last-modified"),
    size,
    last_used: order,
    order,
  }
  let mut replaced = false
  let mut index = 0
  while index < self.entries.length() {
    if cache_entry_matches(self.entries[index], entry.key, request.headers) &&
      self.entries[index].vary_signature == entry.vary_signature {
      self.cache_remove_at(index)
      replaced = true
      break
    }
    index += 1
  }
  self.total_bytes += entry.size
  self.entries.push(entry)
  self.cache_enforce_limits()
  let retained = self.entries.any(fn(candidate) {
    candidate.key == entry.key &&
    candidate.vary_signature == entry.vary_signature
  })
  if !retained {
    Ok(CacheNotStored(CacheFull))
  } else if replaced {
    Ok(CacheReplaced)
  } else {
    Ok(CacheStored)
  }
}

///|
/// Looks up a GET/HEAD representation under the request's Vary dimensions.
pub fn HttpCache::lookup(
  self : HttpCache,
  request : @types.Request[Unit],
  now_seconds : Int64,
) -> Result[CacheLookup, CacheError] {
  let request_control = match
    cache_request_control(request, self.config.limits.max_directives) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let key = match cache_base_key(request) {
    Ok(value) => value
    Err(_) =>
      return Ok(
        if request_control.only_if_cached {
          OnlyIfCachedMiss
        } else {
          CacheMiss
        },
      )
  }
  if request.headers.get_string("range") is Some(_) ||
    request.headers.get_string("if-range") is Some(_) {
    return Ok(
      if request_control.only_if_cached {
        OnlyIfCachedMiss
      } else {
        CacheMiss
      },
    )
  }
  let mut selected = -1
  for index, entry in self.entries {
    if cache_entry_matches(entry, key, request.headers) {
      selected = index
      break
    }
  }
  if selected < 0 {
    if request_control.only_if_cached {
      return Ok(OnlyIfCachedMiss)
    }
    return Ok(CacheMiss)
  }
  let entry = self.entries[selected]
  entry.last_used = self.cache_tick()
  let age = cache_add_saturating(
    entry.initial_age,
    (now_seconds - entry.stored_at).max(0L),
  )
  let remaining = entry.freshness_lifetime - age
  let request_age_ok = match request_control.max_age {
    Some(limit) => age <= limit
    None => true
  }
  let allow_error_fallback = !request_control.no_cache && request_age_ok
  let fresh = request_age_ok &&
    remaining >= request_control.min_fresh.unwrap_or(0L) &&
    remaining > 0L
  if fresh && !request_control.no_cache && !entry.no_cache {
    return Ok(
      CacheFresh(cache_entry_hit(entry, request, age, 0L, allow_error_fallback)),
    )
  }
  let stale = (-remaining).max(0L)
  let max_stale_ok = match request_control.max_stale {
    Some(limit) => stale <= limit
    None => request_control.max_stale_any
  }
  if !request_control.no_cache &&
    request_age_ok &&
    !entry.no_cache &&
    !entry.must_revalidate &&
    (
      max_stale_ok ||
      (
        entry.stale_while_revalidate > 0L &&
        stale <= entry.stale_while_revalidate
      )
    ) {
    return Ok(
      CacheStale(
        cache_entry_hit(entry, request, age, stale, allow_error_fallback),
      ),
    )
  }
  if request_control.only_if_cached {
    Ok(OnlyIfCachedMiss)
  } else if entry.etag is Some(_) || entry.last_modified is Some(_) {
    Ok(
      CacheRevalidate(
        cache_entry_hit(entry, request, age, stale, allow_error_fallback),
      ),
    )
  } else {
    Ok(CacheMiss)
  }
}
