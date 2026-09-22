///|
pub(all) suberror HttpDateError {
  InvalidHttpDate
  ObsoleteDateRequiresCurrentTime
  HttpDateOutOfRange
} derive(Eq, Debug)

///|
pub(all) struct HttpDate {
  unix_seconds : Int64
} derive(Eq, Debug, Compare)

///|
fn date_leap_year(year : Int) -> Bool {
  year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}

///|
fn date_days_in_month(year : Int, month : Int) -> Int {
  match month {
    1 | 3 | 5 | 7 | 8 | 10 | 12 => 31
    4 | 6 | 9 | 11 => 30
    2 => if date_leap_year(year) { 29 } else { 28 }
    _ => 0
  }
}

///|
fn date_floor_div(value : Int64, divisor : Int64) -> Int64 {
  let quotient = value / divisor
  let remainder = value % divisor
  if remainder < 0L {
    quotient - 1L
  } else {
    quotient
  }
}

///|
fn date_floor_mod(value : Int64, divisor : Int64) -> Int64 {
  let result = value % divisor
  if result < 0L {
    result + divisor
  } else {
    result
  }
}

///|
fn days_from_civil(year : Int, month : Int, day : Int) -> Int64 {
  let adjusted_year = year.to_int64() - (if month <= 2 { 1L } else { 0L })
  let era = date_floor_div(adjusted_year, 400L)
  let year_of_era = adjusted_year - era * 400L
  let adjusted_month = month.to_int64() + (if month > 2 { -3L } else { 9L })
  let day_of_year = (153L * adjusted_month + 2L) / 5L + day.to_int64() - 1L
  let day_of_era = year_of_era * 365L +
    year_of_era / 4L -
    year_of_era / 100L +
    day_of_year
  era * 146097L + day_of_era - 719468L
}

///|
fn civil_from_days(days : Int64) -> (Int, Int, Int) {
  let shifted = days + 719468L
  let era = date_floor_div(shifted, 146097L)
  let day_of_era = shifted - era * 146097L
  let year_of_era = (
      day_of_era -
      day_of_era / 1460L +
      day_of_era / 36524L -
      day_of_era / 146096L
    ) /
    365L
  let mut year = year_of_era + era * 400L
  let day_of_year = day_of_era -
    (365L * year_of_era + year_of_era / 4L - year_of_era / 100L)
  let month_prime = (5L * day_of_year + 2L) / 153L
  let day = day_of_year - (153L * month_prime + 2L) / 5L + 1L
  let month = month_prime + (if month_prime < 10L { 3L } else { -9L })
  if month <= 2L {
    year += 1L
  }
  (year.to_int(), month.to_int(), day.to_int())
}

///|
fn date_parse_digits(bytes : BytesView, start : Int, count : Int) -> Int? {
  if start < 0 ||
    count <= 0 ||
    start > bytes.length() ||
    count > bytes.length() - start {
    return None
  }
  let mut value = 0
  for index in start..<(start + count) {
    let byte = bytes[index]
    if byte < b'0' || byte > b'9' {
      return None
    }
    value = value * 10 + byte.to_int() - 48
  }
  Some(value)
}

///|
fn date_month(bytes : BytesView, start : Int) -> Int? {
  if start < 0 || start > bytes.length() || bytes.length() - start < 3 {
    return None
  }
  match bytes[start:start + 3] {
    b"Jan" => Some(1)
    b"Feb" => Some(2)
    b"Mar" => Some(3)
    b"Apr" => Some(4)
    b"May" => Some(5)
    b"Jun" => Some(6)
    b"Jul" => Some(7)
    b"Aug" => Some(8)
    b"Sep" => Some(9)
    b"Oct" => Some(10)
    b"Nov" => Some(11)
    b"Dec" => Some(12)
    _ => None
  }
}

///|
fn date_weekday(bytes : BytesView, start : Int) -> Int? {
  if start < 0 || start > bytes.length() || bytes.length() - start < 3 {
    return None
  }
  match bytes[start:start + 3] {
    b"Sun" => Some(0)
    b"Mon" => Some(1)
    b"Tue" => Some(2)
    b"Wed" => Some(3)
    b"Thu" => Some(4)
    b"Fri" => Some(5)
    b"Sat" => Some(6)
    _ => None
  }
}

///|
fn date_components_to_seconds(
  weekday : Int,
  year : Int,
  month : Int,
  day : Int,
  hour : Int,
  minute : Int,
  second : Int,
) -> Result[Int64, HttpDateError] {
  if year < 1601 ||
    year > 9999 ||
    month < 1 ||
    month > 12 ||
    day < 1 ||
    day > date_days_in_month(year, month) ||
    hour < 0 ||
    hour > 23 ||
    minute < 0 ||
    minute > 59 ||
    second < 0 ||
    second > 59 {
    return Err(HttpDateOutOfRange)
  }
  let days = days_from_civil(year, month, day)
  if weekday != date_floor_mod(days + 4L, 7L).to_int() {
    return Err(InvalidHttpDate)
  }
  Ok(
    days * 86400L +
    hour.to_int64() * 3600L +
    minute.to_int64() * 60L +
    second.to_int64(),
  )
}

///|
pub fn HttpDate::from_components(
  year : Int,
  month : Int,
  day : Int,
  hour : Int,
  minute : Int,
  second : Int,
) -> Result[HttpDate, HttpDateError] {
  if year < 1601 ||
    year > 9999 ||
    month < 1 ||
    month > 12 ||
    day < 1 ||
    day > date_days_in_month(year, month) ||
    hour < 0 ||
    hour > 23 ||
    minute < 0 ||
    minute > 59 ||
    second < 0 ||
    second > 59 {
    return Err(HttpDateOutOfRange)
  }
  Ok({
    unix_seconds: days_from_civil(year, month, day) * 86400L +
    hour.to_int64() * 3600L +
    minute.to_int64() * 60L +
    second.to_int64(),
  })
}

///|
fn parse_imf_fixdate(bytes : BytesView) -> Result[Int64, HttpDateError] {
  if bytes.length() != 29 ||
    bytes[3:5] != b", " ||
    bytes[7] != b' ' ||
    bytes[11] != b' ' ||
    bytes[16] != b' ' ||
    bytes[19] != b':' ||
    bytes[22] != b':' ||
    bytes[25:] != b" GMT" {
    return Err(InvalidHttpDate)
  }
  let weekday = match date_weekday(bytes, 0) {
    Some(value) => value
    None => return Err(InvalidHttpDate)
  }
  let day = match date_parse_digits(bytes, 5, 2) {
    Some(value) => value
    None => return Err(InvalidHttpDate)
  }
  let month = match date_month(bytes, 8) {
    Some(value) => value
    None => return Err(InvalidHttpDate)
  }
  let year = match date_parse_digits(bytes, 12, 4) {
    Some(value) => value
    None => return Err(InvalidHttpDate)
  }
  let hour = match date_parse_digits(bytes, 17, 2) {
    Some(value) => value
    None => return Err(InvalidHttpDate)
  }
  let minute = match date_parse_digits(bytes, 20, 2) {
    Some(value) => value
    None => return Err(InvalidHttpDate)
  }
  let second = match date_parse_digits(bytes, 23, 2) {
    Some(value) => value
    None => return Err(InvalidHttpDate)
  }
  date_components_to_seconds(weekday, year, month, day, hour, minute, second)
}

///|
fn rfc850_weekday(bytes : BytesView) -> (Int, Int)? {
  let names : Array[(Bytes, Int)] = [
    (b"Sunday", 0),
    (b"Monday", 1),
    (b"Tuesday", 2),
    (b"Wednesday", 3),
    (b"Thursday", 4),
    (b"Friday", 5),
    (b"Saturday", 6),
  ]
  for entry in names {
    let (name, weekday) = entry
    if bytes.length() > name.length() &&
      bytes[:name.length()] == name &&
      bytes[name.length()] == b',' {
      return Some((weekday, name.length() + 2))
    }
  }
  None
}

///|
fn parse_rfc850_date(
  bytes : BytesView,
  now_seconds : Int64?,
) -> Result[Int64, HttpDateError] {
  let (weekday, start) = match rfc850_weekday(bytes) {
    Some(value) => value
    None => return Err(InvalidHttpDate)
  }
  if bytes.length() - start != 22 ||
    bytes[start + 2] != b'-' ||
    bytes[start + 6] != b'-' ||
    bytes[start + 9] != b' ' ||
    bytes[start + 12] != b':' ||
    bytes[start + 15] != b':' ||
    bytes[start + 18:] != b" GMT" {
    return Err(InvalidHttpDate)
  }
  let current = match now_seconds {
    Some(value) => value
    None => return Err(ObsoleteDateRequiresCurrentTime)
  }
  let current_year = civil_from_days(date_floor_div(current, 86400L)).0
  let year_suffix = match date_parse_digits(bytes, start + 7, 2) {
    Some(value) => value
    None => return Err(InvalidHttpDate)
  }
  let mut year = current_year / 100 * 100 + year_suffix
  if year > current_year + 50 {
    year -= 100
  }
  let day = match date_parse_digits(bytes, start, 2) {
    Some(value) => value
    None => return Err(InvalidHttpDate)
  }
  let month = match date_month(bytes, start + 3) {
    Some(value) => value
    None => return Err(InvalidHttpDate)
  }
  let hour = match date_parse_digits(bytes, start + 10, 2) {
    Some(value) => value
    None => return Err(InvalidHttpDate)
  }
  let minute = match date_parse_digits(bytes, start + 13, 2) {
    Some(value) => value
    None => return Err(InvalidHttpDate)
  }
  let second = match date_parse_digits(bytes, start + 16, 2) {
    Some(value) => value
    None => return Err(InvalidHttpDate)
  }
  date_components_to_seconds(weekday, year, month, day, hour, minute, second)
}

///|
fn parse_asctime_date(bytes : BytesView) -> Result[Int64, HttpDateError] {
  if bytes.length() != 24 ||
    bytes[3] != b' ' ||
    bytes[7] != b' ' ||
    bytes[10] != b' ' ||
    bytes[13] != b':' ||
    bytes[16] != b':' ||
    bytes[19] != b' ' {
    return Err(InvalidHttpDate)
  }
  let weekday = match date_weekday(bytes, 0) {
    Some(value) => value
    None => return Err(InvalidHttpDate)
  }
  let month = match date_month(bytes, 4) {
    Some(value) => value
    None => return Err(InvalidHttpDate)
  }
  let day = if bytes[8] == b' ' {
    match date_parse_digits(bytes, 9, 1) {
      Some(value) => value
      None => return Err(InvalidHttpDate)
    }
  } else {
    match date_parse_digits(bytes, 8, 2) {
      Some(value) => value
      None => return Err(InvalidHttpDate)
    }
  }
  let hour = match date_parse_digits(bytes, 11, 2) {
    Some(value) => value
    None => return Err(InvalidHttpDate)
  }
  let minute = match date_parse_digits(bytes, 14, 2) {
    Some(value) => value
    None => return Err(InvalidHttpDate)
  }
  let second = match date_parse_digits(bytes, 17, 2) {
    Some(value) => value
    None => return Err(InvalidHttpDate)
  }
  let year = match date_parse_digits(bytes, 20, 4) {
    Some(value) => value
    None => return Err(InvalidHttpDate)
  }
  date_components_to_seconds(weekday, year, month, day, hour, minute, second)
}

///|
pub fn HttpDate::parse(
  value : String,
  now_seconds? : Int64? = None,
) -> Result[HttpDate, HttpDateError] {
  let bytes = @utf8.encode(value)
  let parsed = if bytes.length() >= 4 && bytes[3] == b',' {
    parse_imf_fixdate(bytes)
  } else if rfc850_weekday(bytes) is Some(_) {
    parse_rfc850_date(bytes, now_seconds)
  } else {
    parse_asctime_date(bytes)
  }
  match parsed {
    Ok(unix_seconds) => Ok({ unix_seconds, })
    Err(error) => Err(error)
  }
}

///|
pub fn HttpDate::from_unix_seconds(
  unix_seconds : Int64,
) -> Result[HttpDate, HttpDateError] {
  let (year, _, _) = civil_from_days(date_floor_div(unix_seconds, 86400L))
  if year < 1601 || year > 9999 {
    Err(HttpDateOutOfRange)
  } else {
    Ok({ unix_seconds, })
  }
}

///|
pub fn HttpDate::unix_seconds(self : HttpDate) -> Int64 {
  self.unix_seconds
}

///|
fn date_two_digits(value : Int) -> String {
  if value < 10 {
    "0" + value.to_string()
  } else {
    value.to_string()
  }
}

///|
fn date_four_digits(value : Int) -> String {
  if value < 10 {
    "000" + value.to_string()
  } else if value < 100 {
    "00" + value.to_string()
  } else if value < 1000 {
    "0" + value.to_string()
  } else {
    value.to_string()
  }
}

///|
pub fn HttpDate::format(self : HttpDate) -> Result[String, HttpDateError] {
  let days = date_floor_div(self.unix_seconds, 86400L)
  let seconds_of_day = date_floor_mod(self.unix_seconds, 86400L)
  let (year, month, day) = civil_from_days(days)
  if year < 1601 || year > 9999 {
    return Err(HttpDateOutOfRange)
  }
  let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  let months = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov",
    "Dec",
  ]
  let weekday = date_floor_mod(days + 4L, 7L).to_int()
  let hour = (seconds_of_day / 3600L).to_int()
  let minute = (seconds_of_day % 3600L / 60L).to_int()
  let second = (seconds_of_day % 60L).to_int()
  Ok(
    weekdays[weekday] +
    ", " +
    date_two_digits(day) +
    " " +
    months[month - 1] +
    " " +
    date_four_digits(year) +
    " " +
    date_two_digits(hour) +
    ":" +
    date_two_digits(minute) +
    ":" +
    date_two_digits(second) +
    " GMT",
  )
}
