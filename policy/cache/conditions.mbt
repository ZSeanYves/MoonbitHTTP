///|
/// Adds validators for a conditional revalidation request. Existing caller
/// validators are preserved; the returned map is always a private copy.
pub fn conditional_request_headers(
  request_headers : @types.HeaderMap,
  hit : CacheHit,
) -> @types.HeaderMap {
  let output = cache_clone_headers(request_headers)
  if output.get_string("if-none-match") is None {
    match hit.etag {
      Some(value) => ignore(output.append_string("if-none-match", value))
      None => ()
    }
  }
  if output.get_string("if-none-match") is None &&
    output.get_string("if-modified-since") is None {
    match hit.last_modified {
      Some(value) => ignore(output.append_string("if-modified-since", value))
      None => ()
    }
  }
  output
}

///|
fn cache_strip_weak(value : String) -> String {
  if value.has_prefix("W/") {
    value[2:].to_owned()
  } else {
    value
  }
}

///|
pub fn etag_matches(
  request_value : String,
  stored_value : String,
  weak~ : Bool = true,
) -> CacheCondition {
  if !cache_etag_valid(stored_value) {
    return ConditionMalformed
  }
  for candidate_view in request_value.split(",") {
    let candidate = candidate_view.trim().to_owned()
    if candidate == "*" {
      return ConditionMatches
    }
    if !cache_etag_valid(candidate) {
      continue
    }
    let left = if weak { cache_strip_weak(candidate) } else { candidate }
    let right = if weak { cache_strip_weak(stored_value) } else { stored_value }
    if left == right {
      return ConditionMatches
    }
  }
  ConditionDoesNotMatch
}

///|
pub fn evaluate_request_condition(
  request : @types.Request[Unit],
  hit : CacheHit,
  now_seconds : Int64,
) -> Result[CacheCondition, CacheError] {
  match request.headers.get_string("if-none-match") {
    Some(value) =>
      match hit.etag {
        Some(etag) => Ok(etag_matches(value.to_string_lossy(), etag))
        None => Ok(ConditionDoesNotMatch)
      }
    None =>
      match request.headers.get_string("if-modified-since") {
        Some(value) if hit.last_modified is Some(last) => {
          let requested = match
            @types.HttpDate::parse(
              value.to_string_lossy(),
              now_seconds=Some(now_seconds),
            ) {
            Ok(date) => date.unix_seconds()
            Err(_) => return Ok(ConditionMalformed)
          }
          let stored = match
            @types.HttpDate::parse(last, now_seconds=Some(now_seconds)) {
            Ok(date) => date.unix_seconds()
            Err(_) => return Ok(ConditionMalformed)
          }
          Ok(
            if stored <= requested {
              ConditionMatches
            } else {
              ConditionDoesNotMatch
            },
          )
        }
        Some(_) => Ok(ConditionDoesNotMatch)
        None => Ok(ConditionAbsent)
      }
  }
}
