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
  if request_value.trim() == "*" {
    return ConditionMatches
  }
  let right = if weak { cache_strip_weak(stored_value) } else { stored_value }
  let mut quoted = false
  let mut start = 0
  for end in 0..<=request_value.length() {
    if end < request_value.length() {
      if request_value[end] == '"' {
        quoted = !quoted
      }
      if request_value[end] != ',' || quoted {
        continue
      }
    }
    let candidate = request_value[start:end].trim().to_owned()
    start = end + 1
    if quoted || !cache_etag_valid(candidate) {
      continue
    }
    let left = if weak { cache_strip_weak(candidate) } else { candidate }
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
  let tags = request.headers.get_all_string("if-none-match")
  if !tags.is_empty() {
    if tags.length() == 1 && tags[0].to_string_lossy().trim() == "*" {
      return Ok(ConditionMatches)
    }
    guard hit.etag is Some(etag) else { return Ok(ConditionDoesNotMatch) }
    let field = tags.map(v => v.to_string_lossy()).join(",")
    return Ok(etag_matches(field, etag))
  }
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
