///|
fn cache_merge_304_headers(
  stored : @types.HeaderMap,
  not_modified : @types.HeaderMap,
) -> @types.HeaderMap {
  let output = stored.copy()
  let replaced : Map[String, Unit] = Map([])
  for field in not_modified.fields() {
    if field.name.value
      is ("content-length"
      | "content-encoding"
      | "transfer-encoding"
      | "trailer") {
      continue
    }
    if !replaced.contains(field.name.value) {
      output.remove(field.name)
      replaced.set(field.name.value, ())
    }
    output.append(field.name, field.value)
  }
  output
}

///|
/// Applies a validated 304 response to the matching stored representation and
/// returns the refreshed representation. Pass the actual conditional request;
/// both its validator and any returned validator must identify the stored body.
/// A 304 body is never retained.
pub fn HttpCache::revalidate(
  self : HttpCache,
  request : @types.Request[Unit],
  not_modified : @types.Response[Unit],
  now_seconds : Int64,
) -> Result[CacheHit, CacheError] {
  if not_modified.status != 304 {
    return Err(InvalidResponse)
  }
  if request.headers.get_string("range") is Some(_) ||
    request.headers.get_string("if-range") is Some(_) {
    return Err(InvalidRequest)
  }
  if not_modified.headers.content_length() is Err(_) {
    return Err(InvalidResponse)
  }
  let key = match cache_base_key(request) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  guard self.matching_entry(key, request.headers) is Some(old) else {
    return Err(NotCacheable("304 has no matching stored representation"))
  }
  let response_etag = match cache_validator(not_modified.headers, "etag") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match response_etag {
    Some(value) => {
      guard old.etag is Some(stored) &&
        cache_strip_weak(value) == cache_strip_weak(stored) else {
        return Err(InvalidValidator)
      }
    }
    None => ()
  }
  let conditional_tags = request.headers.get_all_string("if-none-match")
  if !conditional_tags.is_empty() {
    guard conditional_tags.length() == 1 && old.etag is Some(stored) else {
      return Err(InvalidValidator)
    }
    let sent = conditional_tags[0].to_string_lossy().trim().to_owned()
    // Without a response ETag, a list or wildcard cannot identify which
    // representation the origin validated. Our own request uses one tag.
    if response_etag is None {
      if !cache_etag_valid(sent) ||
        cache_strip_weak(sent) != cache_strip_weak(stored) {
        return Err(InvalidValidator)
      }
    } else if etag_matches(sent, stored) != ConditionMatches {
      return Err(InvalidValidator)
    }
  } else {
    let dates = request.headers.get_all_string("if-modified-since")
    guard dates.length() == 1 && old.last_modified is Some(stored) else {
      return Err(InvalidValidator)
    }
    if dates[0].to_string_lossy() != stored {
      return Err(InvalidValidator)
    }
  }
  match cache_header_text(not_modified.headers, "last-modified") {
    Some(value) if old.last_modified != Some(value) =>
      return Err(InvalidValidator)
    _ => ()
  }
  let merged : @types.Response[Unit] = {
    status: old.response.status,
    version: old.response.version,
    headers: cache_merge_304_headers(old.response.headers, not_modified.headers),
    body: (),
  }
  // A conditional HEAD can refresh an existing GET body, but must not create
  // a bodyless GET entry through the ordinary store API.
  let storage_request = { ..request, http_method: Get, }
  match
    self.store(
      storage_request,
      merged,
      old.body,
      now_seconds,
      trailers=old.trailers,
    ) {
    Ok(CacheStored | CacheReplaced) => ()
    Ok(CacheNotStored(reason)) => return Err(reason)
    Err(error) => return Err(error)
  }
  match self.lookup(request, now_seconds) {
    Ok(CacheFresh(hit) | CacheStale(hit) | CacheRevalidate(hit)) => Ok(hit)
    Ok(CacheMiss | OnlyIfCachedMiss) =>
      Err(NotCacheable("refreshed representation is unavailable"))
    Err(error) => Err(error)
  }
}
