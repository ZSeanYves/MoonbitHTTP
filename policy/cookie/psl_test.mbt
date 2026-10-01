///|
test "psl: exact ICANN rules return the effective TLD plus one" {
  assert_eq(@cookie.public_suffix("a.b.example.co.uk"), Ok("co.uk"))
  assert_eq(
    @cookie.registrable_domain("a.b.example.co.uk"),
    Ok("example.co.uk"),
  )
  assert_eq(@cookie.public_suffix("www.example.com"), Ok("com"))
  assert_eq(@cookie.registrable_domain("www.example.com"), Ok("example.com"))
}

///|
test "psl: wildcard and exception rules follow prevailing-rule semantics" {
  assert_eq(@cookie.public_suffix("a.b.ck"), Ok("b.ck"))
  assert_eq(@cookie.registrable_domain("a.b.ck"), Ok("a.b.ck"))
  assert_eq(@cookie.public_suffix("www.ck"), Ok("ck"))
  assert_eq(@cookie.registrable_domain("www.ck"), Ok("www.ck"))
}

///|
test "psl: private domains are included in the same security boundary" {
  assert_eq(@cookie.public_suffix("tenant.github.io"), Ok("github.io"))
  assert_eq(
    @cookie.registrable_domain("tenant.github.io"),
    Ok("tenant.github.io"),
  )
  assert_eq(@cookie.is_public_suffix("github.io"), Ok(true))
}

///|
test "psl: IDNA labels are canonicalized before lookup" {
  assert_eq(@cookie.normalize_domain("食狮.COM.CN"), Ok("xn--85x722f.com.cn"))
  assert_eq(@cookie.public_suffix("食狮.COM.CN"), Ok("com.cn"))
  assert_eq(
    @cookie.registrable_domain("www.食狮.COM.CN"),
    Ok("xn--85x722f.com.cn"),
  )
}

///|
test "psl: unknown TLDs use the implicit wildcard rule" {
  assert_eq(@cookie.public_suffix("a.example.unknown-tld"), Ok("unknown-tld"))
  assert_eq(
    @cookie.registrable_domain("a.example.unknown-tld"),
    Ok("example.unknown-tld"),
  )
}

///|
test "psl: public suffixes and IP literals cannot become registrable sites" {
  assert_eq(
    @cookie.registrable_domain("co.uk"),
    Err(PublicSuffixHasNoRegistrableDomain),
  )
  assert_eq(@cookie.public_suffix("127.0.0.1"), Err(IpAddressHasNoPublicSuffix))
  assert_eq(
    @cookie.public_suffix("[2001:db8::1]"),
    Err(IpAddressHasNoPublicSuffix),
  )
  assert_eq(@cookie.normalize_domain("bad..example"), Err(InvalidDomain))
}
