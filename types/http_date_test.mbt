///|
test "http date: all RFC 9110 wire formats decode identically" {
  let expected = 784111777L
  assert_eq(
    @types.HttpDate::parse("Sun, 06 Nov 1994 08:49:37 GMT").unwrap().unix_seconds,
    expected,
  )
  assert_eq(
    @types.HttpDate::parse(
      "Sunday, 06-Nov-94 08:49:37 GMT",
      now_seconds=Some(1767225600L),
    ).unwrap().unix_seconds,
    expected,
  )
  assert_eq(
    @types.HttpDate::parse("Sun Nov  6 08:49:37 1994").unwrap().unix_seconds,
    expected,
  )
}

///|
test "http date: epoch and leap day round-trip to IMF-fixdate" {
  let epoch = @types.HttpDate::parse("Thu, 01 Jan 1970 00:00:00 GMT").unwrap()
  assert_eq(epoch.unix_seconds, 0L)
  assert_eq(epoch.format(), Ok("Thu, 01 Jan 1970 00:00:00 GMT"))
  let leap = @types.HttpDate::parse("Tue, 29 Feb 2000 23:59:59 GMT").unwrap()
  assert_eq(
    @types.HttpDate::from_unix_seconds(leap.unix_seconds).unwrap().format(),
    Ok("Tue, 29 Feb 2000 23:59:59 GMT"),
  )
}

///|
test "http date: checked components support protocol date parsers" {
  assert_eq(
    @types.HttpDate::from_components(1994, 11, 6, 8, 49, 37).unwrap().unix_seconds,
    784111777L,
  )
  assert_true(
    @types.HttpDate::from_components(1900, 2, 29, 0, 0, 0)
    is Err(HttpDateOutOfRange),
  )
}

///|
test "http date: malformed values and missing current time are rejected" {
  assert_true(
    @types.HttpDate::parse("Sunday, 06-Nov-94 08:49:37 GMT")
    is Err(ObsoleteDateRequiresCurrentTime),
  )
  assert_true(
    @types.HttpDate::parse("Mon, 06 Nov 1994 08:49:37 GMT")
    is Err(InvalidHttpDate),
  )
  assert_true(
    @types.HttpDate::parse("Thu, 29 Feb 1900 00:00:00 GMT")
    is Err(HttpDateOutOfRange),
  )
  assert_true(
    @types.HttpDate::parse("Sun, 06 Nov 1994 08:49:60 GMT")
    is Err(HttpDateOutOfRange),
  )
}
