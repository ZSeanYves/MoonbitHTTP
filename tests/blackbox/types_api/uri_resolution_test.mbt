///|
test "uri resolution: resolves common HTTP Location references" {
  let base = @types.Uri::parse("https://example.com/a/b/index?q=old").unwrap()
  assert_eq(
    @types.Uri::resolve_reference(base, "../next?x=1").unwrap().value,
    "https://example.com/a/next?x=1",
  )
  assert_eq(
    @types.Uri::resolve_reference(base, "/root/./x/../y").unwrap().value,
    "https://example.com/root/y",
  )
  assert_eq(
    @types.Uri::resolve_reference(base, "?q=new").unwrap().value,
    "https://example.com/a/b/index?q=new",
  )
  assert_eq(
    @types.Uri::resolve_reference(base, "#fragment").unwrap().value,
    "https://example.com/a/b/index?q=old",
  )
}

///|
test "uri resolution: handles network paths and strips fragments" {
  let base = @types.Uri::parse("https://example.com/base").unwrap()
  assert_eq(
    @types.Uri::resolve_reference(base, "//other.example/path#section").unwrap().value,
    "https://other.example/path",
  )
  assert_eq(
    @types.Uri::resolve_reference(base, "http://other.example/x#section").unwrap().value,
    "http://other.example/x",
  )
}

///|
test "uri resolution: rejects credentials and control bytes" {
  let base = @types.Uri::parse("https://example.com/base").unwrap()
  assert_true(
    @types.Uri::resolve_reference(base, "//user:pass@other.example/path")
    is Err(UserinfoNotAllowed),
  )
  assert_true(
    @types.Uri::resolve_reference(base, "/ok\r\nInjected: yes") is Err(_),
  )
  let origin = @types.Uri::parse("/relative").unwrap()
  assert_true(
    @types.Uri::resolve_reference(origin, "/next") is Err(InvalidRequestTarget),
  )
}

///|
test "uri resolution: normalize only literal dot segments in a Location with authority" {
  let base = @types.Uri::parse("https://base.test/a").unwrap()
  for
    (location, expected) in [
      ("http://origin.test/docs/../index", "http://origin.test/index"),
      ("//origin.test/a/./b/..", "https://origin.test/a/"),
      ("https://origin.test/a//../b", "https://origin.test/a/b"),
      ("https://origin.test/a//.", "https://origin.test/a//"),
      (
        "https://origin.test/%2e%2e/x?q=/a/../b#frag", "https://origin.test/%2e%2e/x?q=/a/../b",
      ),
    ] {
    assert_eq(
      @types.Uri::resolve_reference(base, location).unwrap().value,
      expected,
    )
  }
}
