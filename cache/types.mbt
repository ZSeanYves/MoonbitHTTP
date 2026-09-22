///|
pub(all) suberror CacheError {
  InvalidLimits
  InvalidCacheControl
  InvalidAge
  InvalidVary
  InvalidRequest
  InvalidResponse
  EntryTooLarge(Int)
  CacheFull
  NotCacheable(String)
  InvalidDate
  InvalidValidator
} derive(Eq, Debug)

///|
pub(all) struct CacheLimits {
  max_entries : Int
  max_total_bytes : Int
  max_entry_bytes : Int
  max_metadata_bytes : Int
  max_vary_fields : Int
  max_directives : Int
  heuristic_max_age_seconds : Int64
} derive(Eq, Debug)

///|
pub fn CacheLimits::defaults() -> CacheLimits {
  {
    max_entries: 1024,
    max_total_bytes: 64 * 1024 * 1024,
    max_entry_bytes: 8 * 1024 * 1024,
    max_metadata_bytes: 64 * 1024,
    max_vary_fields: 32,
    max_directives: 64,
    heuristic_max_age_seconds: 86400L,
  }
}

///|
pub fn CacheLimits::validate(self : CacheLimits) -> Result[Unit, CacheError] {
  if self.max_entries < 1 ||
    self.max_total_bytes < 1 ||
    self.max_entry_bytes < 1 ||
    self.max_entry_bytes > self.max_total_bytes ||
    self.max_metadata_bytes < 1 ||
    self.max_vary_fields < 1 ||
    self.max_directives < 1 ||
    self.heuristic_max_age_seconds < 0L {
    Err(InvalidLimits)
  } else {
    Ok(())
  }
}

///|
pub(all) struct CacheConfig {
  limits : CacheLimits
  shared : Bool
  allow_heuristic_freshness : Bool
  allow_set_cookie : Bool
}

///|
pub fn CacheConfig::defaults() -> CacheConfig {
  {
    limits: CacheLimits::defaults(),
    shared: false,
    allow_heuristic_freshness: false,
    allow_set_cookie: false,
  }
}

///|
pub fn CacheConfig::validate(self : CacheConfig) -> Result[Unit, CacheError] {
  self.limits.validate()
}

///|
pub(all) struct CacheControl {
  mut no_cache : Bool
  mut no_store : Bool
  mut max_age : Int64?
  mut s_maxage : Int64?
  mut max_stale : Int64?
  mut max_stale_any : Bool
  mut min_fresh : Int64?
  mut stale_while_revalidate : Int64?
  mut stale_if_error : Int64?
  mut must_revalidate : Bool
  mut proxy_revalidate : Bool
  mut public : Bool
  mut private : Bool
  mut immutable : Bool
  mut no_transform : Bool
  mut only_if_cached : Bool
} derive(Eq, Debug)

///|
pub fn CacheControl::empty() -> CacheControl {
  {
    no_cache: false,
    no_store: false,
    max_age: None,
    s_maxage: None,
    max_stale: None,
    max_stale_any: false,
    min_fresh: None,
    stale_while_revalidate: None,
    stale_if_error: None,
    must_revalidate: false,
    proxy_revalidate: false,
    public: false,
    private: false,
    immutable: false,
    no_transform: false,
    only_if_cached: false,
  }
}

///|
pub(all) enum CacheLookup {
  CacheMiss
  OnlyIfCachedMiss
  CacheFresh(CacheHit)
  CacheStale(CacheHit)
  CacheRevalidate(CacheHit)
}

///|
pub(all) struct CacheHit {
  response : @types.Response[Unit]
  body : Bytes
  age_seconds : Int64
  freshness_lifetime : Int64
  stale_seconds : Int64
  stale_if_error : Int64
  etag : String?
  last_modified : String?
}

///|
pub fn CacheHit::response(self : CacheHit) -> @types.Response[Unit] {
  self.response
}

///|
pub fn CacheHit::body(self : CacheHit) -> Bytes {
  self.body
}

///|
pub fn CacheHit::age_seconds(self : CacheHit) -> Int64 {
  self.age_seconds
}

///|
pub fn CacheHit::freshness_lifetime(self : CacheHit) -> Int64 {
  self.freshness_lifetime
}

///|
pub fn CacheHit::stale_seconds(self : CacheHit) -> Int64 {
  self.stale_seconds
}

///|
pub fn CacheHit::stale_if_error(self : CacheHit) -> Int64 {
  self.stale_if_error
}

///|
pub fn CacheHit::etag(self : CacheHit) -> String? {
  self.etag
}

///|
pub fn CacheHit::last_modified(self : CacheHit) -> String? {
  self.last_modified
}

///|
pub(all) enum CacheStoreOutcome {
  CacheStored
  CacheReplaced
  CacheNotStored(CacheError)
} derive(Eq, Debug)

///|
pub(all) enum CacheCondition {
  ConditionMatches
  ConditionDoesNotMatch
  ConditionAbsent
  ConditionMalformed
} derive(Eq, Debug)
