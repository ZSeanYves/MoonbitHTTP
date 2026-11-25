///|
#derive(Eq, Debug)
pub(all) suberror DomainError {
  InvalidDomain
  IpAddressHasNoPublicSuffix
  PublicSuffixHasNoRegistrableDomain
}

///|
priv struct CookieHost {
  name : String
  ip_literal : Bool
}

///|
/// Cookie matching also treats four decimal octets with leading zeroes as an address.
fn cookie_is_ipv4(host : String) -> Bool {
  if host.length() < 7 || host.length() > 15 {
    return false
  }
  let mut dots = 0
  let mut digits = 0
  let mut octet = 0
  for c in host {
    match c {
      '0'..<='9' => {
        digits += 1
        octet = octet * 10 + (c.to_int() - '0'.to_int())
        if digits > 3 || octet > 255 {
          return false
        }
      }
      '.' if digits > 0 && dots < 3 => {
        dots += 1
        digits = 0
        octet = 0
      }
      _ => return false
    }
  }
  dots == 3 && digits > 0
}

///|
fn classify_cookie_host(host : String) -> Result[CookieHost, DomainError] {
  if host.has_prefix("[") {
    guard host.has_suffix("]") &&
      @types.Authority::parse(host)
      is Ok({ ip_literal: true, host: address, userinfo: None, port: None, .. }) else {
      return Err(InvalidDomain)
    }
    // IPvFuture syntax can otherwise collide with an ordinary DNS name.
    let name = if address.has_prefix("v") {
      "[" + address + "]"
    } else {
      address
    }
    return Ok({ name, ip_literal: true, })
  }
  if host.contains(":") {
    return @types.IpAddress::parse(host)
      .map(addr => { name: addr.value(), ip_literal: true, })
      .map_err(_ => InvalidDomain)
  }
  let name = @idna.to_ascii(
    host,
    use_std3_ascii_rules=true,
    check_hyphens=true,
    check_bidi=true,
    check_joiners=true,
    verify_dns_length=true,
  ) catch {
    _ => return Err(InvalidDomain)
  }
  if name.is_empty() || name.has_suffix(".") {
    return Err(InvalidDomain)
  }
  Ok({ name, ip_literal: cookie_is_ipv4(name), })
}

///|
pub fn normalize_domain(host : String) -> Result[String, DomainError] {
  match classify_cookie_host(host) {
    Ok({ ip_literal: true, .. }) => Err(IpAddressHasNoPublicSuffix)
    Ok(host) => Ok(host.name)
    Err(error) => Err(error)
  }
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
fn psl_suffix_length(labels : Array[StringView]) -> Int32 {
  let mut best = 1
  for start in 0..<labels.length() {
    let candidate = labels[start:].join(".")
    let count = labels.length() - start
    if psl_contains(psl_exception_rules, candidate) {
      return count - 1
    }
    if count > best && psl_contains(psl_exact_rules, candidate) {
      best = count
    }
    if start > 0 &&
      count + 1 > best &&
      psl_contains(psl_wildcard_rules, candidate) {
      best = count + 1
    }
  }
  best
}

///|
pub fn public_suffix(host : String) -> Result[String, DomainError] {
  normalize_domain(host).map(name => {
    let labels = name.split(".").to_array()
    labels[labels.length() - psl_suffix_length(labels):].join(".")
  })
}

///|
fn is_normalized_public_suffix(name : String) -> Bool {
  let labels = name.split(".").to_array()
  labels.length() == psl_suffix_length(labels)
}

///|
pub fn is_public_suffix(host : String) -> Result[Bool, DomainError] {
  normalize_domain(host).map(is_normalized_public_suffix)
}

///|
pub fn registrable_domain(host : String) -> Result[String, DomainError] {
  let normalized = match normalize_domain(host) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let labels = normalized.split(".").to_array()
  let length = psl_suffix_length(labels)
  if length == labels.length() {
    return Err(PublicSuffixHasNoRegistrableDomain)
  }
  Ok(labels[labels.length() - length - 1:].join("."))
}
