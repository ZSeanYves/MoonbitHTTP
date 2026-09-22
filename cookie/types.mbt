///|
pub(all) suberror CookieError {
  InvalidCookieLimits
  InvalidCookieRequestUri
  CookieHeaderLimitExceeded
} derive(Eq, Debug)

///|
pub(all) enum CookieRejection {
  CookieJarDisabled
  MalformedSetCookie
  CookieTooLarge
  CookieAttributeTooLarge
  InvalidCookieDomain
  CookieDomainMismatch
  CookiePublicSuffix
  SecureCookieFromInsecureOrigin
  SecureCookieOverlay
  HttpOnlyFromNonHttpApi
  SameSiteContextRejected
  SameSiteNoneWithoutSecure
  CookiePrefixViolation
  PartitionedCookieUnsupported
} derive(Eq, Debug)

///|
pub(all) enum CookieStoreOutcome {
  CookieStored
  CookieReplaced
  CookieDeleted
  CookieIgnored(CookieRejection)
} derive(Eq, Debug)

///|
pub(all) enum CookieSameSite {
  SameSiteDefault
  SameSiteStrict
  SameSiteLax
  SameSiteNone
} derive(Eq, Debug)

///|
pub(all) enum CookieApi {
  HttpCookieApi
  NonHttpCookieApi
} derive(Eq, Debug)

///|
pub(all) struct CookieContext {
  http_method : @types.Method
  api : CookieApi
  same_site : Bool
  top_level_navigation : Bool
} derive(Eq, Debug)

///|
pub fn CookieContext::http(
  http_method : @types.Method,
  same_site? : Bool = true,
  top_level_navigation? : Bool = false,
) -> CookieContext {
  { http_method, api: HttpCookieApi, same_site, top_level_navigation, }
}

///|
pub fn CookieContext::non_http(same_site? : Bool = true) -> CookieContext {
  {
    http_method: Get,
    api: NonHttpCookieApi,
    same_site,
    top_level_navigation: false,
  }
}

///|
pub(all) struct CookieLimits {
  max_set_cookie_bytes : Int
  max_cookie_bytes : Int
  max_attribute_bytes : Int
  max_cookie_header_bytes : Int
  max_cookies : Int
  max_cookies_per_domain : Int
  max_lifetime_seconds : Int64
} derive(Eq, Debug)

///|
pub fn CookieLimits::defaults() -> CookieLimits {
  {
    max_set_cookie_bytes: 16384,
    max_cookie_bytes: 4096,
    max_attribute_bytes: 1024,
    max_cookie_header_bytes: 32768,
    max_cookies: 3000,
    max_cookies_per_domain: 180,
    max_lifetime_seconds: 34560000L,
  }
}

///|
pub fn CookieLimits::validate(self : CookieLimits) -> Result[Unit, CookieError] {
  if self.max_set_cookie_bytes < self.max_cookie_bytes ||
    self.max_cookie_bytes < 1 ||
    self.max_attribute_bytes < 1 ||
    self.max_cookie_header_bytes < 1 ||
    self.max_cookies < 1 ||
    self.max_cookies_per_domain < 1 ||
    self.max_cookies_per_domain > self.max_cookies ||
    self.max_lifetime_seconds < 1L {
    Err(InvalidCookieLimits)
  } else {
    Ok(())
  }
}

///|
pub struct Cookie {
  name : Bytes
  value : Bytes
  domain : String
  path : Bytes
  expiry_seconds : Int64?
  persistent : Bool
  host_only : Bool
  secure : Bool
  http_only : Bool
  same_site : CookieSameSite
  creation_order : Int64
  mut last_access_order : Int64
}

///|
priv struct ParsedSetCookie {
  name : Bytes
  value : Bytes
  domain : String?
  path : Bytes?
  explicit_path : Bool
  max_age_seconds : Int64?
  expires_seconds : Int64?
  secure : Bool
  http_only : Bool
  same_site : CookieSameSite
  partitioned : Bool
}
