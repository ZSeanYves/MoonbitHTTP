///|
test "types: HeaderMap preserves duplicates and normalizes names" {
  let headers = HeaderMap::new()
  assert_eq(headers.append_string("Set-Cookie", "a=1"), Ok(()))
  assert_eq(headers.append_string("set-cookie", "b=2"), Ok(()))
  let values = headers.get_all_string("SET-COOKIE")
  assert_eq(values.length(), 2)
  assert_eq(values[0].to_string_lossy(), "a=1")
  assert_eq(values[1].to_string_lossy(), "b=2")
  assert_eq(headers.fields()[0].name.value, "set-cookie")
}

///|
test "types: rejects header injection" {
  assert_eq(HeaderValue::from_string("ok\r\ninjected: yes") is Err(_), true)
  assert_eq(HeaderName::parse("bad name") is Err(_), true)
}

///|
test "types: response body rules" {
  assert_eq(response_allows_body(Get, 200), true)
  assert_eq(response_allows_body(Head, 200), false)
  assert_eq(response_allows_body(Get, 204), false)
  assert_eq(response_allows_body(Connect, 200), false)
}
