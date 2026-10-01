///|
fn uri_valid_ipv4_octet(input : BytesView) -> Bool {
  if input.is_empty() || input.length() > 3 {
    return false
  }
  if input.length() > 1 && input[0] == b'0' {
    return false
  }
  let mut value = 0
  for byte in input {
    if !uri_is_digit(byte) {
      return false
    }
    value = value * 10 + byte.to_int() - 48
  }
  value <= 255
}

///|
fn uri_valid_ipv4(input : BytesView) -> Bool {
  let mut start = 0
  let mut octets = 0
  for index in 0..<=input.length() {
    if index == input.length() || input[index] == b'.' {
      if !uri_valid_ipv4_octet(input[start:index]) {
        return false
      }
      octets += 1
      start = index + 1
    }
  }
  octets == 4
}

///|
fn uri_valid_ipv6_group(input : BytesView) -> Bool {
  if input.is_empty() || input.length() > 4 {
    return false
  }
  for byte in input {
    if !uri_is_hex(byte) {
      return false
    }
  }
  true
}

///|
fn uri_valid_ipv6(input : BytesView) -> Bool {
  if input.is_empty() {
    return false
  }
  let mut index = 0
  let mut groups = 0
  let mut compressed = false
  if input[0] == b':' {
    if input.length() < 2 || input[1] != b':' {
      return false
    }
    compressed = true
    index = 2
    if index == input.length() {
      return true
    }
  }
  while index < input.length() {
    let start = index
    while index < input.length() && input[index] != b':' {
      index += 1
    }
    if start == index {
      return false
    }
    let group = input[start:index]
    let mut ipv4_tail = false
    for byte in group {
      if byte == b'.' {
        ipv4_tail = true
        break
      }
    }
    if ipv4_tail {
      if index != input.length() || !uri_valid_ipv4(group) {
        return false
      }
      groups += 2
    } else {
      if !uri_valid_ipv6_group(group) {
        return false
      }
      groups += 1
    }
    if groups > 8 {
      return false
    }
    if index == input.length() {
      break
    }
    if index + 1 < input.length() && input[index + 1] == b':' {
      if compressed {
        return false
      }
      compressed = true
      index += 2
      if index == input.length() {
        break
      }
    } else {
      index += 1
      if index == input.length() {
        return false
      }
    }
  }
  if compressed {
    groups < 8
  } else {
    groups == 8
  }
}

///|
/// A numeric IP literal. Construction validates the value; DNS names and brackets are not accepted.
pub struct IpAddress {
  value : String
} derive(Debug, Eq, Compare)

///|
pub(all) suberror IpAddressError {
  InvalidLiteral
} derive(Debug, Eq)

///|
pub fn IpAddress::parse(value : String) -> Result[IpAddress, IpAddressError] {
  let bytes = @utf8.encode(value)
  guard uri_valid_ipv4(bytes) || uri_valid_ipv6(bytes) else {
    return Err(InvalidLiteral)
  }
  Ok({ value: ascii_lower(bytes), })
}

///|
pub fn IpAddress::value(self : IpAddress) -> String {
  self.value
}
