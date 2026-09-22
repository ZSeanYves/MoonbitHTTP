///|
fn cookie_test_uri(value : String) -> @types.Uri {
  @types.Uri::parse(value).unwrap()
}

///|
fn cookie_header_text(
  jar : @cookie.CookieJar,
  uri : String,
  now_seconds : Int64,
  context? : @cookie.CookieContext = @cookie.CookieContext::http(Get),
) -> Result[String?, @cookie.CookieError] {
  match jar.cookie_header(cookie_test_uri(uri), now_seconds, context~) {
    Ok(Some(value)) => Ok(Some(value.to_string_lossy()))
    Ok(None) => Ok(None)
    Err(error) => Err(error)
  }
}

///|
test "cookie jar: disabled-by-default storage is inert" {
  let jar = @cookie.CookieJar::new().unwrap()
  assert_eq(
    jar.store_string("sid=secret", cookie_test_uri("https://example.com/"), 0L),
    Ok(CookieIgnored(CookieJarDisabled)),
  )
  assert_eq(cookie_header_text(jar, "https://example.com/", 0L), Ok(None))
  assert_eq(jar.size(), 0)
}

///|
test "cookie jar: host-only, domain, and path scopes are distinct" {
  let jar = @cookie.CookieJar::new(enabled=true).unwrap()
  jar.store_string(
    "host=one",
    cookie_test_uri("https://www.example.com/a/index"),
    0L,
  )
  |> ignore
  jar.store_string(
    "domain=two; Domain=example.com; Path=/a",
    cookie_test_uri("https://www.example.com/a/index"),
    0L,
  )
  |> ignore
  assert_eq(
    cookie_header_text(jar, "https://www.example.com/a/child", 1L),
    Ok(Some("host=one; domain=two")),
  )
  assert_eq(
    cookie_header_text(jar, "https://api.example.com/a/child", 2L),
    Ok(Some("domain=two")),
  )
  assert_eq(cookie_header_text(jar, "https://api.example.com/ab", 3L), Ok(None))
}

///|
test "cookie jar: unrelated and public-suffix Domain attributes are rejected" {
  let jar = @cookie.CookieJar::new(enabled=true).unwrap()
  let origin = cookie_test_uri("https://shop.example.co.uk/")
  assert_eq(
    jar.store_string("a=1; Domain=evil.example", origin, 0L),
    Ok(CookieIgnored(CookieDomainMismatch)),
  )
  assert_eq(
    jar.store_string("a=1; Domain=co.uk", origin, 0L),
    Ok(CookieIgnored(CookiePublicSuffix)),
  )
  assert_eq(
    jar.store_string("a=1; Domain=example.co.uk.", origin, 0L),
    Ok(CookieIgnored(InvalidCookieDomain)),
  )
  assert_eq(jar.size(), 0)
}

///|
test "cookie jar: a public-suffix host is forced to host-only scope" {
  let jar = @cookie.CookieJar::new(enabled=true).unwrap()
  assert_eq(
    jar.store_string("a=1; Domain=co.uk", cookie_test_uri("https://co.uk/"), 0L),
    Ok(CookieStored),
  )
  assert_eq(cookie_header_text(jar, "https://co.uk/", 1L), Ok(Some("a=1")))
  assert_eq(cookie_header_text(jar, "https://x.co.uk/", 2L), Ok(None))
}

///|
test "cookie jar: Max-Age wins over Expires and expires at the boundary" {
  let jar = @cookie.CookieJar::new(enabled=true).unwrap()
  let origin = cookie_test_uri("https://example.com/")
  assert_eq(
    jar.store_string(
      "sid=one; Expires=Sun, 06 Nov 1994 08:49:37 GMT; Max-Age=10", origin, 784111777L,
    ),
    Ok(CookieStored),
  )
  assert_eq(
    cookie_header_text(jar, "https://example.com/", 784111786L),
    Ok(Some("sid=one")),
  )
  assert_eq(
    cookie_header_text(jar, "https://example.com/", 784111787L),
    Ok(None),
  )
}

///|
test "cookie jar: permissive cookie-date parsing and deletion are deterministic" {
  let jar = @cookie.CookieJar::new(enabled=true).unwrap()
  let origin = cookie_test_uri("https://example.com/")
  assert_eq(
    jar.store_string(
      "sid=one; Expires=garbage 06-Nov-94 08:49:40 more", origin, 784111777L,
    ),
    Ok(CookieStored),
  )
  assert_eq(
    cookie_header_text(jar, "https://example.com/", 784111779L),
    Ok(Some("sid=one")),
  )
  assert_eq(
    cookie_header_text(jar, "https://example.com/", 784111780L),
    Ok(None),
  )
  jar.store_string("sid=two", origin, 784111800L) |> ignore
  assert_eq(
    jar.store_string("sid=; Max-Age=-999999999999999999999", origin, 784111801L),
    Ok(CookieDeleted),
  )
  assert_eq(
    cookie_header_text(jar, "https://example.com/", 784111801L),
    Ok(None),
  )
}

///|
test "cookie jar: persistent lifetime is capped to 400 days by default" {
  let jar = @cookie.CookieJar::new(enabled=true).unwrap()
  let origin = cookie_test_uri("https://example.com/")
  jar.store_string("long=one; Max-Age=999999999999999999999999", origin, 1000L)
  |> ignore
  assert_eq(
    cookie_header_text(jar, "https://example.com/", 34560999L),
    Ok(Some("long=one")),
  )
  assert_eq(
    cookie_header_text(jar, "https://example.com/", 34561000L),
    Ok(None),
  )
}

///|
test "cookie jar: Secure cookies require TLS and resist insecure overlay" {
  let jar = @cookie.CookieJar::new(enabled=true).unwrap()
  assert_eq(
    jar.store_string(
      "sid=bad; Secure",
      cookie_test_uri("http://example.com/"),
      0L,
    ),
    Ok(CookieIgnored(SecureCookieFromInsecureOrigin)),
  )
  jar.store_string(
    "sid=good; Secure; Path=/login",
    cookie_test_uri("https://example.com/login"),
    1L,
  )
  |> ignore
  assert_eq(
    jar.store_string(
      "sid=evil; Path=/login",
      cookie_test_uri("http://example.com/login/page"),
      2L,
    ),
    Ok(CookieIgnored(SecureCookieOverlay)),
  )
  assert_eq(
    cookie_header_text(jar, "https://example.com/login", 3L),
    Ok(Some("sid=good")),
  )
  assert_eq(cookie_header_text(jar, "http://example.com/login", 4L), Ok(None))
}

///|
test "cookie jar: HttpOnly blocks non-HTTP reads, replacement, and deletion" {
  let jar = @cookie.CookieJar::new(enabled=true).unwrap()
  let origin = cookie_test_uri("https://example.com/")
  jar.store_string("sid=good; HttpOnly", origin, 0L) |> ignore
  assert_eq(
    cookie_header_text(
      jar,
      "https://example.com/",
      1L,
      context=@cookie.CookieContext::non_http(),
    ),
    Ok(None),
  )
  assert_eq(
    jar.store_string(
      "sid=evil",
      origin,
      2L,
      context=@cookie.CookieContext::non_http(),
    ),
    Ok(CookieIgnored(HttpOnlyFromNonHttpApi)),
  )
  assert_eq(
    jar.store_string(
      "sid=; Max-Age=0",
      origin,
      3L,
      context=@cookie.CookieContext::non_http(),
    ),
    Ok(CookieIgnored(HttpOnlyFromNonHttpApi)),
  )
  assert_eq(
    cookie_header_text(jar, "https://example.com/", 4L),
    Ok(Some("sid=good")),
  )
}

///|
test "cookie jar: prefix guarantees are ASCII-case-insensitive" {
  let jar = @cookie.CookieJar::new(enabled=true).unwrap()
  let origin = cookie_test_uri("https://example.com/")
  assert_eq(
    jar.store_string("__SeCuRe-id=bad", origin, 0L),
    Ok(CookieIgnored(CookiePrefixViolation)),
  )
  assert_eq(
    jar.store_string(
      "__HOST-id=bad; Secure; Path=/; Domain=example.com", origin, 0L,
    ),
    Ok(CookieIgnored(CookiePrefixViolation)),
  )
  assert_eq(
    jar.store_string("__hOsT-id=good; Secure; Path=/", origin, 0L),
    Ok(CookieStored),
  )
  assert_eq(
    jar.store_string("=__Secure-disguised; Secure", origin, 0L),
    Ok(CookieIgnored(CookiePrefixViolation)),
  )
}

///|
test "cookie jar: SameSite enforces cross-site creation and retrieval" {
  let jar = @cookie.CookieJar::new(enabled=true).unwrap()
  let origin = cookie_test_uri("https://example.com/")
  jar.store_string("strict=1; SameSite=Strict; Secure", origin, 0L) |> ignore
  jar.store_string("lax=1; SameSite=Lax; Secure", origin, 0L) |> ignore
  jar.store_string("none=1; SameSite=None; Secure", origin, 0L) |> ignore
  assert_eq(
    jar.store_string("bad=1; SameSite=None", origin, 0L),
    Ok(CookieIgnored(SameSiteNoneWithoutSecure)),
  )
  let cross_subresource = @cookie.CookieContext::http(Get, same_site=false)
  assert_eq(
    cookie_header_text(
      jar,
      "https://example.com/",
      1L,
      context=cross_subresource,
    ),
    Ok(Some("none=1")),
  )
  let cross_navigation = @cookie.CookieContext::http(
    Get,
    same_site=false,
    top_level_navigation=true,
  )
  assert_eq(
    cookie_header_text(
      jar,
      "https://example.com/",
      2L,
      context=cross_navigation,
    ),
    Ok(Some("lax=1; none=1")),
  )
  let unsafe_navigation = @cookie.CookieContext::http(
    Post,
    same_site=false,
    top_level_navigation=true,
  )
  assert_eq(
    cookie_header_text(
      jar,
      "https://example.com/",
      3L,
      context=unsafe_navigation,
    ),
    Ok(Some("none=1")),
  )
  assert_eq(
    jar.store_string(
      "created=bad; SameSite=Strict",
      origin,
      4L,
      context=cross_subresource,
    ),
    Ok(CookieIgnored(SameSiteContextRejected)),
  )
}

///|
test "cookie jar: Partitioned cookies fail closed without a partition key" {
  let jar = @cookie.CookieJar::new(enabled=true).unwrap()
  assert_eq(
    jar.store_string(
      "sid=one; Secure; Partitioned",
      cookie_test_uri("https://example.com/"),
      0L,
    ),
    Ok(CookieIgnored(PartitionedCookieUnsupported)),
  )
}

///|
test "cookie jar: duplicate attributes use the last recognized value" {
  let jar = @cookie.CookieJar::new(enabled=true).unwrap()
  let origin = cookie_test_uri("https://www.example.com/")
  assert_eq(
    jar.store_string("a=1; Domain=evil.example; Domain=example.com", origin, 0L),
    Ok(CookieStored),
  )
  assert_eq(
    jar.store_string("b=1; Domain=example.com; Domain=evil.example", origin, 0L),
    Ok(CookieIgnored(CookieDomainMismatch)),
  )
}

///|
test "cookie jar: path length and original creation order control serialization" {
  let jar = @cookie.CookieJar::new(enabled=true).unwrap()
  let origin = cookie_test_uri("https://example.com/app/page")
  jar.store_string("first=old; Path=/", origin, 0L) |> ignore
  jar.store_string("second=two; Path=/", origin, 1L) |> ignore
  jar.store_string("deep=three; Path=/app", origin, 2L) |> ignore
  jar.store_string("first=new; Path=/", origin, 3L) |> ignore
  assert_eq(
    cookie_header_text(jar, "https://example.com/app/child", 4L),
    Ok(Some("deep=three; first=new; second=two")),
  )
}

///|
test "cookie jar: per-domain eviction protects Secure cookies first" {
  let defaults = @cookie.CookieLimits::defaults()
  let limits = { ..defaults, max_cookies: 2, max_cookies_per_domain: 1, }
  let jar = @cookie.CookieJar::new(enabled=true, limits~).unwrap()
  let origin = cookie_test_uri("https://example.com/")
  jar.store_string("secure=one; Secure", origin, 0L) |> ignore
  jar.store_string("plain=two", origin, 1L) |> ignore
  assert_eq(jar.size(now_seconds=2L), 1)
  assert_eq(
    cookie_header_text(jar, "https://example.com/", 2L),
    Ok(Some("secure=one")),
  )
}

///|
test "cookie jar: malformed, oversized, IP-domain, and output-limit cases are typed" {
  let defaults = @cookie.CookieLimits::defaults()
  let limits = { ..defaults, max_cookie_header_bytes: 4, }
  let jar = @cookie.CookieJar::new(enabled=true, limits~).unwrap()
  let origin = cookie_test_uri("https://example.com/")
  assert_eq(
    jar.store_string("bad\r\nInjected: yes", origin, 0L),
    Ok(CookieIgnored(MalformedSetCookie)),
  )
  assert_eq(
    jar.store_string("x=" + "a".repeat(4097), origin, 0L),
    Ok(CookieIgnored(CookieTooLarge)),
  )
  jar.store_string("token=abc", origin, 0L) |> ignore
  assert_eq(
    cookie_header_text(jar, "https://example.com/", 1L),
    Err(CookieHeaderLimitExceeded),
  )
  assert_eq(
    jar.store_string(
      "a=1; Domain=127.0.0.1",
      cookie_test_uri("http://127.0.0.1/"),
      0L,
    ),
    Ok(CookieIgnored(InvalidCookieDomain)),
  )
  assert_true(
    @cookie.CookieJar::new(limits={ ..defaults, max_cookies: 0, })
    is Err(InvalidCookieLimits),
  )
}

///|
test "cookie jar: session cleanup preserves only persistent cookies" {
  let jar = @cookie.CookieJar::new(enabled=true).unwrap()
  let origin = cookie_test_uri("https://example.com/")
  jar.store_string("session=one", origin, 0L) |> ignore
  jar.store_string("persistent=two; Max-Age=60", origin, 0L) |> ignore
  jar.clear_session()
  assert_eq(jar.size(now_seconds=1L), 1)
  assert_eq(
    cookie_header_text(jar, "https://example.com/", 1L),
    Ok(Some("persistent=two")),
  )
  jar.clear()
  assert_eq(jar.size(now_seconds=1L), 0)
}
