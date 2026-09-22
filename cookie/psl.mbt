///|
pub(all) suberror DomainError {
  InvalidDomain
  IpAddressHasNoPublicSuffix
  PublicSuffixHasNoRegistrableDomain
} derive(Eq, Debug)

///|
fn psl_is_ipv4(value : String) -> Bool {
  let parts : Array[StringView] = value.split(".").collect()
  if parts.length() != 4 {
    return false
  }
  for part in parts {
    if part.is_empty() || part.length() > 3 {
      return false
    }
    let mut octet = 0
    for character in part {
      if character < '0' || character > '9' {
        return false
      }
      octet = octet * 10 + character.to_int() - 48
    }
    if octet > 255 {
      return false
    }
  }
  true
}

///|
fn psl_is_ip_literal(value : String) -> Bool {
  value.contains(":") || psl_is_ipv4(value) || @crater_psl.is_ip_literal(value)
}

///|
pub fn normalize_domain(host : String) -> Result[String, DomainError] {
  let unbracketed = if host.has_prefix("[") &&
    host.has_suffix("]") &&
    host.length() > 2 {
    host[1:host.length() - 1].to_owned()
  } else {
    host
  }
  if psl_is_ip_literal(unbracketed) {
    return Err(IpAddressHasNoPublicSuffix)
  }
  let ascii = @idna.to_ascii(
    unbracketed,
    use_std3_ascii_rules=true,
    check_hyphens=true,
    check_bidi=true,
    check_joiners=true,
    verify_dns_length=true,
  ) catch {
    _ => return Err(InvalidDomain)
  }
  let normalized = @crater_psl.normalize_host(ascii)
  if normalized.is_empty() ||
    normalized.has_prefix(".") ||
    normalized.contains("..") {
    return Err(InvalidDomain)
  }
  Ok(normalized)
}

///|
fn psl_contains(rules : Array[String], value : String) -> Bool {
  let mut low = 0
  let mut high = rules.length()
  while low < high {
    let middle = low + (high - low) / 2
    let comparison = value.compare(rules[middle])
    if comparison == 0 {
      return true
    } else if comparison < 0 {
      high = middle
    } else {
      low = middle + 1
    }
  }
  false
}

///|
fn psl_split_labels(value : String) -> Array[String] {
  let labels : Array[String] = []
  for label in value.split(".") {
    labels.push(label.to_owned())
  }
  labels
}

///|
fn psl_join_labels(labels : Array[String], start : Int) -> String {
  let output = StringBuilder()
  for index in start..<labels.length() {
    if index > start {
      output.write_char('.')
    }
    output.write_string(labels[index])
  }
  output.to_string()
}

///|
fn psl_suffix_length(normalized : String) -> Int {
  let labels = psl_split_labels(normalized)
  let mut best = 1
  let mut exception = 0
  for start in 0..<labels.length() {
    let candidate = psl_join_labels(labels, start)
    let candidate_labels = labels.length() - start
    if psl_contains(psl_exact_rules, candidate) && candidate_labels > best {
      best = candidate_labels
    }
    if psl_contains(psl_exception_rules, candidate) &&
      candidate_labels > exception {
      exception = candidate_labels
    }
    if start + 1 < labels.length() {
      let wildcard_base = psl_join_labels(labels, start + 1)
      if psl_contains(psl_wildcard_rules, wildcard_base) &&
        candidate_labels > best {
        best = candidate_labels
      }
    }
  }
  if exception > 0 {
    exception - 1
  } else {
    best
  }
}

///|
pub fn public_suffix(host : String) -> Result[String, DomainError] {
  let normalized = match normalize_domain(host) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let labels = psl_split_labels(normalized)
  Ok(psl_join_labels(labels, labels.length() - psl_suffix_length(normalized)))
}

///|
pub fn is_public_suffix(host : String) -> Result[Bool, DomainError] {
  let normalized = match normalize_domain(host) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match public_suffix(normalized) {
    Ok(value) => Ok(value == normalized)
    Err(error) => Err(error)
  }
}

///|
pub fn registrable_domain(host : String) -> Result[String, DomainError] {
  let normalized = match normalize_domain(host) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let labels = psl_split_labels(normalized)
  let suffix_length = psl_suffix_length(normalized)
  if labels.length() <= suffix_length {
    return Err(PublicSuffixHasNoRegistrableDomain)
  }
  Ok(psl_join_labels(labels, labels.length() - suffix_length - 1))
}
