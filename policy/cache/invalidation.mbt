///|
/// Invalidates all representations for a URI after a successful unsafe
/// method or an explicit caller decision.
pub fn HttpCache::invalidate(
  self : HttpCache,
  request : @types.Request[Unit],
) -> Result[Unit, CacheError] {
  let key = match
    cache_base_key({
      http_method: Get,
      uri: request.uri,
      version: request.version,
      headers: request.headers,
      body: (),
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  self.discard_pending(key)
  let mut index = self.entries.length() - 1
  while index >= 0 {
    if self.entries[index].key == key {
      self.cache_remove_at(index)
    }
    index -= 1
  }
  Ok(())
}

///|
/// Returns the canonical cache key for an absolute URI.
fn cache_key_for_uri(uri : @types.Uri) -> Result[String, CacheError] {
  cache_base_key({
    http_method: Get,
    uri,
    version: Http11,
    headers: @types.HeaderMap::new(),
    body: (),
  })
}

///|
/// Compares only the origin components used by HTTP cache invalidation.
fn cache_same_origin(left : @types.Uri, right : @types.Uri) -> Bool {
  let left_scheme = left.scheme
  let right_scheme = right.scheme
  if left_scheme != right_scheme {
    return false
  }
  match (left.authority, right.authority) {
    (Some(a), Some(b)) => {
      let left_port = a.port.unwrap_or(
        if left_scheme == Some("https") {
          443
        } else {
          80
        },
      )
      let right_port = b.port.unwrap_or(
        if right_scheme == Some("https") {
          443
        } else {
          80
        },
      )
      a.host == b.host &&
      a.ip_literal == b.ip_literal &&
      left_port == right_port
    }
    _ => false
  }
}

///|
/// Invalidates the effective request URI and same-origin Location targets.
/// This is intended for successful unsafe methods (POST/PUT/DELETE/etc.).
pub fn HttpCache::invalidate_response(
  self : HttpCache,
  request : @types.Request[Unit],
  response : @types.Response[Unit],
) -> Result[Unit, CacheError] {
  if request.http_method is (Get | Head | Options | Trace) ||
    response.status < 200 ||
    response.status >= 400 {
    return Ok(())
  }
  match request.uri.validate() {
    Ok(_) => ()
    Err(_) => return Err(InvalidRequest)
  }
  let target_key = match cache_key_for_uri(request.uri) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let keys : Array[String] = [target_key]
  for field_name in ["location", "content-location"] {
    for value in response.headers.get_all_string(field_name) {
      let resolved = match
        @types.Uri::resolve_reference(request.uri, value.to_string_lossy()) {
        Ok(uri) => uri
        Err(_) => continue
      }
      if !cache_same_origin(request.uri, resolved) {
        continue
      }
      let key = match cache_key_for_uri(resolved) {
        Ok(value) => value
        Err(_) => continue
      }
      let mut duplicate = false
      for existing in keys {
        if existing == key {
          duplicate = true
          break
        }
      }
      if !duplicate {
        keys.push(key)
      }
    }
  }
  for key in keys {
    self.discard_pending(key)
    let mut index = self.entries.length() - 1
    while index >= 0 {
      if self.entries[index].key == key {
        self.cache_remove_at(index)
      }
      index -= 1
    }
  }
  Ok(())
}
