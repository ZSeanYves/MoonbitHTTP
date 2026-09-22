///|
pub(all) struct RedirectDecision {
  uri : @types.Uri
  http_method : @types.Method
  headers : @types.HeaderMap
  drop_body : Bool
  cross_origin : Bool
}

///|
pub struct RedirectTracker {
  policy : RedirectPolicy
  visited : Map[String, Bool]
  mut followed : Int
}

///|
fn redirect_key(uri : @types.Uri) -> Result[String, RedirectError] {
  let endpoint = match ClientEndpoint::from_uri(uri) {
    Ok(value) => value
    Err(_) => return Err(InvalidRedirectLocation)
  }
  let target = match uri.origin_form() {
    Ok(value) => value
    Err(_) => return Err(InvalidRedirectLocation)
  }
  Ok(endpoint.origin + target)
}

///|
pub fn RedirectTracker::new(
  initial : @types.Uri,
  policy : RedirectPolicy,
) -> Result[RedirectTracker, RedirectError] {
  if policy.enabled && policy.max_redirects < 1 {
    return Err(RedirectLimitExceeded(policy.max_redirects))
  }
  let key = match redirect_key(initial) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let visited : Map[String, Bool] = Map([])
  visited.set(key, true)
  Ok({ policy, visited, followed: 0, })
}

///|
fn redirect_headers(
  headers : @types.HeaderMap,
  cross_origin : Bool,
  drop_body : Bool,
) -> @types.HeaderMap {
  let result = @types.HeaderMap::new()
  for field in headers.fields() {
    let name = field.name.value
    let body_metadata = name == "content-length" ||
      name == "transfer-encoding" ||
      name == "content-type" ||
      name == "content-encoding" ||
      name == "content-language" ||
      name == "content-location" ||
      name == "content-md5" ||
      name == "digest" ||
      name == "expect" ||
      name == "trailer"
    if name == "host" ||
      name == "cookie" ||
      name == "proxy-authorization" ||
      (cross_origin && name == "authorization") ||
      (drop_body && body_metadata) {
      continue
    }
    result.append(field.name, field.value)
  }
  result
}

///|
fn redirect_method(
  status : Int,
  http_method : @types.Method,
) -> Result[(@types.Method, Bool), RedirectError] {
  match status {
    301 | 302 if http_method == Post => Ok((Get, true))
    301 | 302 => Ok((http_method, false))
    303 if http_method == Head => Ok((Head, true))
    303 => Ok((Get, true))
    307 | 308 => Ok((http_method, false))
    _ => Err(StatusIsNotRedirect(status))
  }
}

///|
pub fn RedirectTracker::follow(
  self : RedirectTracker,
  current : @types.Uri,
  location : String,
  status : Int,
  http_method : @types.Method,
  headers : @types.HeaderMap,
  body_replayability : BodyReplayability,
) -> Result[RedirectDecision, RedirectError] {
  if !self.policy.enabled {
    return Err(RedirectDisabled)
  }
  if self.followed >= self.policy.max_redirects {
    return Err(RedirectLimitExceeded(self.policy.max_redirects))
  }
  let (next_method, drop_body) = match redirect_method(status, http_method) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !drop_body && body_replayability == NonReplayableBody {
    return Err(RedirectBodyNotReplayable)
  }
  let uri = match @types.Uri::resolve_reference(current, location) {
    Ok(value) => value
    Err(_) => return Err(InvalidRedirectLocation)
  }
  let current_endpoint = match ClientEndpoint::from_uri(current) {
    Ok(value) => value
    Err(_) => return Err(InvalidRedirectLocation)
  }
  let next_endpoint = match ClientEndpoint::from_uri(uri) {
    Ok(value) => value
    Err(_) => return Err(InvalidRedirectLocation)
  }
  if current_endpoint.secure &&
    !next_endpoint.secure &&
    !self.policy.allow_https_downgrade {
    return Err(RedirectDowngradeDenied)
  }
  let key = match redirect_key(uri) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if self.visited.get(key) is Some(_) {
    return Err(RedirectLoop)
  }
  self.visited.set(key, true)
  self.followed += 1
  let cross_origin = !current_endpoint.same_origin(next_endpoint)
  Ok({
    uri,
    http_method: next_method,
    headers: redirect_headers(headers, cross_origin, drop_body),
    drop_body,
    cross_origin,
  })
}
