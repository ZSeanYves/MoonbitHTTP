///|
test "security: nameless cookies cannot alias protected named cookies" {
  let jar = @cookie.CookieJar::new(enabled=true).unwrap()
  let secure = cookie_test_uri("https://example.com/")
  jar.store_string("sid=good; Secure; HttpOnly; Path=/", secure, 0L).unwrap()
  |> ignore
  for
    value in [
      "=sid=evil", " = sid=evil ; Path=/", "=sid=; Max-Age=0", "==sid=evil",
    ] {
    assert_true(
      jar
      .store_string(value, cookie_test_uri("http://example.com/"), 1L)
      .unwrap()
      is CookieIgnored(MalformedSetCookie),
    )
    assert_true(
      jar
      .store_string(
        value,
        secure,
        1L,
        context=@cookie.CookieContext::non_http(),
      )
      .unwrap()
      is CookieIgnored(MalformedSetCookie),
    )
  }
  assert_eq(
    cookie_header_text(jar, "https://example.com/", 2L),
    Ok(Some("sid=good")),
  )
  // Legitimate nameless values and '=' inside named cookie values remain valid.
  jar.store_string("=opaque", secure, 2L).unwrap() |> ignore
  jar.store_string("other=a=b", secure, 2L).unwrap() |> ignore
  assert_eq(
    cookie_header_text(jar, "https://example.com/", 3L),
    Ok(Some("sid=good; opaque; other=a=b")),
  )
}
