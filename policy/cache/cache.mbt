///|
pub struct HttpCache {
  entries : Array[CacheEntry]
  priv pending : Array[CacheFill]
  priv mut pending_bytes : Int32
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
  trailers : @types.HeaderMap?
  date_seconds : Int64
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
    Ok(_) =>
      Ok({
        entries: [],
        pending: [],
        pending_bytes: 0,
        config,
        total_bytes: 0,
        next_order: 0L,
      })
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
  for fill in self.pending {
    fill.chunks = None
  }
  self.pending.clear()
  self.pending_bytes = 0
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
fn cache_clone_response(
  source : @types.Response[Unit],
) -> @types.Response[Unit] {
  {
    status: source.status,
    version: source.version,
    headers: source.headers.copy(),
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
fn cache_metadata_size(headers : @types.HeaderMap) -> Int32 {
  let mut total = 0
  for field in headers.fields() {
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
  let headers = entry.response.headers.copy()
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
    trailers: if request.http_method == Head {
      None
    } else {
      entry.trailers.map(h => h.copy())
    },
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
fn cache_precedes(first : CacheEntry, second : CacheEntry) -> Bool {
  if first.date_seconds != second.date_seconds &&
    first.response.headers.get_string("date") is Some(_) &&
    second.response.headers.get_string("date") is Some(_) {
    first.date_seconds < second.date_seconds
  } else {
    first.order < second.order
  }
}

///|
fn HttpCache::matching_entry(
  self : HttpCache,
  key : String,
  headers : @types.HeaderMap,
) -> CacheEntry? {
  let mut selected : CacheEntry? = None
  for entry in self.entries {
    if !cache_entry_matches(entry, key, headers) {
      continue
    }
    if selected is Some(previous) {
      // RFC 9111 §4.1 prefers a matching Vary response over a default.
      // Within either group, use Date; insertion order breaks ties.
      if entry.vary.is_empty() != previous.vary.is_empty() {
        if entry.vary.is_empty() {
          continue
        }
      } else if cache_precedes(entry, previous) {
        continue
      }
    }
    selected = Some(entry)
  }
  selected
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
  trailers~ : @types.HeaderMap? = None,
) -> Result[CacheStoreOutcome, CacheError] {
  let entry = try {
    let key = self.storage_key(request)
    self.prepare_entry(key, request, response, now_seconds)
  } catch {
    reason if reason is (InvalidRequest | NotCacheable(_) | EntryTooLarge(_)) =>
      return Ok(CacheNotStored(reason))
    error => return Err(error)
  }
  self.store_entry(request, entry, body.length(), () => body, trailers)
}

///|
fn HttpCache::storage_key(
  self : HttpCache,
  request : @types.Request[Unit],
) -> String raise CacheError {
  if request.http_method == Head ||
    request.headers.get_string("range") is Some(_) ||
    request.headers.get_string("if-range") is Some(_) {
    raise NotCacheable("incomplete representation")
  }
  let key = cache_base_key(request).unwrap_or_error()
  let control = cache_request_control(
    request,
    self.config.limits.max_directives,
  ).unwrap_or_error()
  if control.no_store {
    raise NotCacheable("request has no-store")
  }
  key
}

///|
fn HttpCache::prepare_entry(
  self : HttpCache,
  key : String,
  request : @types.Request[Unit],
  response : @types.Response[Unit],
  now_seconds : Int64,
) -> CacheEntry raise CacheError {
  if response.status is (206 | 304) ||
    response.headers.get_string("content-range") is Some(_) {
    raise NotCacheable("incomplete representation")
  }
  if response.status < 100 || response.status > 999 {
    raise InvalidResponse
  }
  let declared = response.headers
    .content_length()
    .map_err(_ => InvalidResponse)
    .unwrap_or_error()
  let control = match
    parse_cache_control(
      response.headers,
      max_directives=self.config.limits.max_directives,
    ) {
    Ok(value) => value
    Err(error) => raise error
  }
  if control.no_store {
    raise NotCacheable("response has no-store")
  }
  if self.config.shared && control.private {
    raise NotCacheable("private response in shared cache")
  }
  if !self.config.allow_set_cookie &&
    response.headers.get_string("set-cookie") is Some(_) {
    raise NotCacheable("set-cookie is not cacheable by policy")
  }
  if request.headers.get_string("authorization") is Some(_) &&
    self.config.shared &&
    !control.public &&
    control.s_maxage is None {
    raise NotCacheable("authorized response lacks shared-cache permission")
  }
  let vary = match
    parse_vary(response.headers, max_fields=self.config.limits.max_vary_fields) {
    Ok((true, _)) => raise NotCacheable("vary wildcard")
    Ok((false, value)) => value
    Err(error) => raise error
  }
  let vary_signature = match cache_vary_signature(request.headers, vary) {
    Ok(value) => value
    Err(error) => raise error
  }
  let date_seconds = match
    cache_parse_date(response.headers, "date", now_seconds) {
    Ok(Some(value)) => value
    Ok(None) => now_seconds
    Err(error) => raise error
  }
  let age_header = match parse_age(response.headers) {
    Ok(value) => value
    Err(error) => raise error
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
    Err(error) => raise error
  }
  if !cache_status_default_cacheable(response.status) &&
    control.max_age is None &&
    control.s_maxage is None &&
    response.headers.get_string("expires") is None {
    raise NotCacheable("status is not cacheable by default")
  }
  let metadata_size = cache_metadata_size(response.headers)
  if metadata_size > self.config.limits.max_metadata_bytes ||
    metadata_size > self.config.limits.max_entry_bytes {
    raise EntryTooLarge(metadata_size)
  }
  if declared is Some(length) &&
    length > (self.config.limits.max_entry_bytes - metadata_size).to_uint64() {
    raise EntryTooLarge(length.min(2147483647UL).to_int())
  }
  {
    key,
    vary,
    vary_signature,
    response: cache_clone_response(response),
    trailers: None,
    body: b"",
    date_seconds,
    stored_at: now_seconds,
    initial_age,
    freshness_lifetime: lifetime,
    stale_while_revalidate: control.stale_while_revalidate.unwrap_or(0L),
    stale_if_error: control.stale_if_error,
    no_cache: control.no_cache,
    must_revalidate: control.must_revalidate || control.proxy_revalidate,
    etag: match cache_validator(response.headers, "etag") {
      Ok(value) => value
      Err(error) => raise error
    },
    last_modified: cache_header_text(response.headers, "last-modified"),
    size: metadata_size,
    last_used: 0L,
    order: self.cache_tick(),
  }
}

///|
fn HttpCache::store_entry(
  self : HttpCache,
  request : @types.Request[Unit],
  head : CacheEntry,
  body_size : Int32,
  make_body : () -> Bytes,
  trailers : @types.HeaderMap?,
) -> Result[CacheStoreOutcome, CacheError] {
  if !self.config.allow_set_cookie &&
    trailers is Some(t) &&
    t.get_string("set-cookie") is Some(_) {
    return Ok(
      CacheNotStored(NotCacheable("set-cookie is not cacheable by policy")),
    )
  }
  if (
      !@types.response_allows_body(request.http_method, head.response.status) &&
      body_size != 0
    ) ||
    (
      head.response.headers.content_length() is Ok(Some(n)) &&
      n != body_size.to_uint64()
    ) {
    return Err(InvalidResponse)
  }
  let metadata_size = head.size + trailers.map(cache_metadata_size).unwrap_or(0)
  if metadata_size > self.config.limits.max_metadata_bytes {
    return Ok(CacheNotStored(EntryTooLarge(metadata_size)))
  }
  if body_size > self.config.limits.max_entry_bytes - metadata_size {
    return Ok(CacheNotStored(EntryTooLarge(body_size)))
  }
  let mut replaced = false
  for index, current in self.entries {
    if current.key == head.key && current.vary_signature == head.vary_signature {
      if cache_precedes(head, current) {
        return Ok(
          CacheNotStored(NotCacheable("a newer representation is stored")),
        )
      }
      self.cache_remove_at(index)
      replaced = true
      break
    }
  }
  let entry = {
    ..head,
    body: make_body(),
    trailers: trailers.map(h => h.copy()),
    size: metadata_size + body_size,
    last_used: self.cache_tick(),
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
  unknown_authorization~ : Bool = false,
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
  guard self.matching_entry(key, request.headers) is Some(entry) &&
    !(unknown_authorization && entry.vary.contains("authorization")) else {
    if request_control.only_if_cached {
      return Ok(OnlyIfCachedMiss)
    }
    return Ok(CacheMiss)
  }
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
