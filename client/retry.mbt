///|
pub(all) enum RetryCause {
  RetryConnectFailure
  RetryTimeoutBeforeResponse
  RetryRefusedStream
  RetryGoawayUnprocessed
  RetryStatus(Int)
  RetryPolicyDenied
  RetryTlsVerificationFailed
  RetryCancelled
  RetryBodyPartiallySent
  RetryOther
} derive(Eq, Debug)

///|
pub(all) enum RetryDecision {
  DoNotRetry
  RetryAfterMillis(Int64)
} derive(Eq, Debug)

///|
fn retry_method_idempotent(http_method : @types.Method) -> Bool {
  http_method == Get ||
  http_method == Head ||
  http_method == Put ||
  http_method == Delete ||
  http_method == Options ||
  http_method == Trace
}

///|
fn retry_method_explicit(
  methods : Array[@types.Method],
  http_method : @types.Method,
) -> Bool {
  for candidate in methods {
    if candidate == http_method {
      return true
    }
  }
  false
}

///|
fn retry_cause_allowed(cause : RetryCause) -> Bool {
  match cause {
    RetryConnectFailure
    | RetryTimeoutBeforeResponse
    | RetryRefusedStream
    | RetryGoawayUnprocessed => true
    RetryStatus(status) =>
      status == 408 ||
      status == 425 ||
      status == 429 ||
      status == 500 ||
      status == 502 ||
      status == 503 ||
      status == 504
    _ => false
  }
}

///|
fn retry_after_millis(
  value : String,
  now_seconds : Int64,
  maximum : Int64,
) -> Int64? {
  let bytes = @utf8.encode(value)
  if !bytes.is_empty() {
    let mut seconds = 0L
    let mut numeric = true
    for byte in bytes {
      if byte < b'0' || byte > b'9' {
        numeric = false
        break
      }
      let digit = (byte.to_int() - 48).to_int64()
      if seconds > (maximum / 1000L - digit) / 10L {
        return Some(maximum)
      }
      seconds = seconds * 10L + digit
    }
    if numeric {
      return Some((seconds * 1000L).min(maximum))
    }
  }
  match @types.HttpDate::parse(value, now_seconds=Some(now_seconds)) {
    Ok(date) =>
      Some(((date.unix_seconds - now_seconds).max(0L) * 1000L).min(maximum))
    Err(_) => None
  }
}

///|
fn retry_backoff(policy : RetryPolicy, completed_attempts : Int) -> Int64 {
  let mut delay = policy.base_delay_ms
  let mut remaining = completed_attempts - 1
  while remaining > 0 && delay < policy.max_delay_ms {
    delay = if delay > policy.max_delay_ms / 2L {
      policy.max_delay_ms
    } else {
      (delay * 2L).min(policy.max_delay_ms)
    }
    remaining -= 1
  }
  delay.min(policy.max_delay_ms)
}

///|
pub fn decide_retry(
  policy : RetryPolicy,
  completed_attempts : Int,
  http_method : @types.Method,
  body_replayability : BodyReplayability,
  cause : RetryCause,
  retry_after? : String? = None,
  now_seconds? : Int64 = 0L,
  jitter_ms? : Int64 = 0L,
) -> Result[RetryDecision, RetryError] {
  match policy.validate() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if completed_attempts < 1 {
    return Err(InvalidRetryPolicy)
  }
  if policy.mode == RetryDisabled ||
    completed_attempts >= policy.max_attempts ||
    !retry_cause_allowed(cause) {
    return Ok(DoNotRetry)
  }
  let method_allowed = match policy.mode {
    RetryIdempotent => retry_method_idempotent(http_method)
    RetryExplicit(methods) => retry_method_explicit(methods, http_method)
    RetryDisabled => false
  }
  if !method_allowed {
    return Ok(DoNotRetry)
  }
  if body_replayability == NonReplayableBody {
    return Err(RetryBodyNotReplayable)
  }
  let base = if policy.respect_retry_after {
    match retry_after {
      Some(value) => retry_after_millis(value, now_seconds, policy.max_delay_ms)
      None => None
    }
  } else {
    None
  }
  let delay = match base {
    Some(value) => value
    None => retry_backoff(policy, completed_attempts)
  }
  let jitter = jitter_ms.max(0L).min(policy.max_delay_ms - delay)
  Ok(RetryAfterMillis(delay + jitter))
}
