///|
test "basic auth: RFC 7617 example encodes exactly" {
  let credentials = @auth.BasicCredentials::new("Aladdin", "open sesame").unwrap()
  assert_eq(
    credentials.authorization().unwrap().to_string_lossy(),
    "Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==",
  )
}

///|
test "basic auth: colon, controls, and bounded credential input are rejected" {
  assert_true(
    @auth.BasicCredentials::new("user:name", "password")
    is Err(InvalidBasicCredentials),
  )
  assert_true(
    @auth.BasicCredentials::new("user", "bad\r\npassword")
    is Err(InvalidBasicCredentials),
  )
  let limits = { ..@auth.AuthLimits::defaults(), max_credential_bytes: 4, }
  assert_true(
    @auth.BasicCredentials::new("user", "pass", limits~)
    is Err(InvalidBasicCredentials),
  )
}

///|
test "basic auth: UTF-8 challenge mode applies NFC before encoding" {
  let decomposed = @auth.BasicCredentials::new("te\u{301}st", "pass").unwrap()
  let composed = @auth.BasicCredentials::new("t\u{e9}st", "pass").unwrap()
  assert_eq(
    decomposed.authorization(utf8_charset=true),
    composed.authorization(utf8_charset=true),
  )
  assert_true(decomposed.authorization() != composed.authorization())
}

///|
test "bearer auth: RFC 6750 token alphabet is strict and injection-safe" {
  let token = @auth.BearerToken::new("abc.DEF_123-~/+==").unwrap()
  assert_eq(
    token.authorization().unwrap().to_string_lossy(),
    "Bearer abc.DEF_123-~/+==",
  )
  for
    invalid in ["", "abc def", "abc=tail", "abc\r\nInjected: yes", "caf\u{e9}"] {
    assert_true(@auth.BearerToken::new(invalid) is Err(InvalidBearerToken))
  }
}
