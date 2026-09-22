///|
fn cookie_date_delimiter(byte : Byte) -> Bool {
  byte == b'\t' ||
  (byte >= b' ' && byte <= b'/') ||
  (byte >= b';' && byte <= b'@') ||
  (byte >= b'[' && byte <= b'`') ||
  (byte >= b'{' && byte <= b'~')
}

///|
fn cookie_date_tokens(input : BytesView) -> Array[Bytes] {
  let tokens : Array[Bytes] = []
  let mut index = 0
  while index < input.length() {
    while index < input.length() && cookie_date_delimiter(input[index]) {
      index += 1
    }
    let start = index
    while index < input.length() && !cookie_date_delimiter(input[index]) {
      index += 1
    }
    if index > start {
      tokens.push(input[start:index].to_owned())
    }
  }
  tokens
}

///|
fn cookie_ascii_lower_byte(byte : Byte) -> Byte {
  if byte >= b'A' && byte <= b'Z' {
    (byte.to_int() + 32).to_byte()
  } else {
    byte
  }
}

///|
fn cookie_date_digits(token : BytesView, minimum : Int, maximum : Int) -> Int? {
  let mut count = 0
  let mut value = 0
  while count < token.length() &&
        count < maximum &&
        token[count] >= b'0' &&
        token[count] <= b'9' {
    value = value * 10 + token[count].to_int() - 48
    count += 1
  }
  if count < minimum ||
    (count < token.length() && token[count] >= b'0' && token[count] <= b'9') {
    None
  } else {
    Some(value)
  }
}

///|
fn cookie_date_time(token : BytesView) -> (Int, Int, Int)? {
  let separators : Array[Int] = []
  for index, byte in token {
    if byte == b':' {
      separators.push(index)
      if separators.length() == 2 {
        break
      }
    }
  }
  guard separators.length() == 2 else { return None }
  let first = separators[0]
  let second = separators[1]
  guard first >= 1 && first <= 2 && second - first >= 2 && second - first <= 3 else {
    return None
  }
  let hour = match cookie_date_digits(token[:first], 1, 2) {
    Some(value) => value
    None => return None
  }
  let minute = match cookie_date_digits(token[first + 1:second], 1, 2) {
    Some(value) => value
    None => return None
  }
  let second_value = match cookie_date_digits(token[second + 1:], 1, 2) {
    Some(value) => value
    None => return None
  }
  Some((hour, minute, second_value))
}

///|
fn cookie_date_month(token : BytesView) -> Int? {
  if token.length() < 3 {
    return None
  }
  let first = cookie_ascii_lower_byte(token[0])
  let second = cookie_ascii_lower_byte(token[1])
  let third = cookie_ascii_lower_byte(token[2])
  match (first, second, third) {
    (b'j', b'a', b'n') => Some(1)
    (b'f', b'e', b'b') => Some(2)
    (b'm', b'a', b'r') => Some(3)
    (b'a', b'p', b'r') => Some(4)
    (b'm', b'a', b'y') => Some(5)
    (b'j', b'u', b'n') => Some(6)
    (b'j', b'u', b'l') => Some(7)
    (b'a', b'u', b'g') => Some(8)
    (b's', b'e', b'p') => Some(9)
    (b'o', b'c', b't') => Some(10)
    (b'n', b'o', b'v') => Some(11)
    (b'd', b'e', b'c') => Some(12)
    _ => None
  }
}

///|
fn parse_cookie_date(input : BytesView) -> Int64? {
  let mut time : (Int, Int, Int)? = None
  let mut day : Int? = None
  let mut month : Int? = None
  let mut year : Int? = None
  for token in cookie_date_tokens(input) {
    if time is None {
      match cookie_date_time(token) {
        Some(value) => {
          time = Some(value)
          continue
        }
        None => ()
      }
    }
    if day is None {
      match cookie_date_digits(token, 1, 2) {
        Some(value) => {
          day = Some(value)
          continue
        }
        None => ()
      }
    }
    if month is None {
      match cookie_date_month(token) {
        Some(value) => {
          month = Some(value)
          continue
        }
        None => ()
      }
    }
    if year is None {
      match cookie_date_digits(token, 2, 4) {
        Some(value) => year = Some(value)
        None => ()
      }
    }
  }
  let (hour, minute, second) = match time {
    Some(value) => value
    None => return None
  }
  let day = match day {
    Some(value) => value
    None => return None
  }
  let month = match month {
    Some(value) => value
    None => return None
  }
  let mut year = match year {
    Some(value) => value
    None => return None
  }
  if year >= 70 && year <= 99 {
    year += 1900
  } else if year >= 0 && year <= 69 {
    year += 2000
  }
  if year < 1601 {
    return None
  }
  match
    @types.HttpDate::from_components(year, month, day, hour, minute, second) {
    Ok(value) => Some(value.unix_seconds)
    Err(_) => None
  }
}
