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
  priv mut visited_for_method : Map[String, Bool]
  mut followed : Int32
}

///|
fn redirect_key(
  uri : @types.Uri,
  endpoint : ClientEndpoint,
) -> Result[String, RedirectError] {
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
  RedirectTracker::from_endpoint(
    initial,
    ClientEndpoint::from_uri(initial),
    policy,
  )
}

///|
fn RedirectTracker::from_endpoint(
  initial : @types.Uri,
  endpoint : Result[ClientEndpoint, ClientError],
  policy : RedirectPolicy,
) -> Result[RedirectTracker, RedirectError] {
  if policy.enabled && policy.max_redirects < 1 {
    return Err(RedirectLimitExceeded(policy.max_redirects))
  }
  guard endpoint is Ok(endpoint) else { return Err(InvalidRedirectLocation) }
  let key = match redirect_key(initial, endpoint) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let visited = Map([(key, true)])
  Ok({ policy, visited_for_method: visited, followed: 0, })
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
  status : Int32,
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
  status : Int32,
  http_method : @types.Method,
  headers : @types.HeaderMap,
  body_replayability : BodyReplayability,
) -> Result[RedirectDecision, RedirectError] {
  let current_endpoint = ClientEndpoint::from_uri(current)
  self
  .resolve(
    current, current_endpoint, location, status, http_method, headers, body_replayability,
  )
  .map(pair => pair.0)
}

///|
fn RedirectTracker::resolve(
  self : RedirectTracker,
  current : @types.Uri,
  current_endpoint : Result[ClientEndpoint, ClientError],
  location : String,
  status : Int32,
  http_method : @types.Method,
  headers : @types.HeaderMap,
  body_replayability : BodyReplayability,
) -> Result[(RedirectDecision, ClientEndpoint), RedirectError] {
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
  guard current_endpoint is Ok(current_endpoint) else {
    return Err(InvalidRedirectLocation)
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
  let key = match redirect_key(uri, next_endpoint) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  // A redirect can rewrite the method only to GET. Once rewritten, all
  // subsequent requests in this chain keep that method.
  if next_method != http_method {
    self.visited_for_method = Map([])
  } else if self.visited_for_method.contains(key) {
    return Err(RedirectLoop)
  }
  self.visited_for_method.set(key, true)
  self.followed += 1
  let cross_origin = !current_endpoint.same_origin(next_endpoint)
  Ok(
    (
      {
        uri,
        http_method: next_method,
        headers: redirect_headers(headers, cross_origin, drop_body),
        drop_body,
        cross_origin,
      },
      next_endpoint,
    ),
  )
}
