///|
pub extend CacheError with Eq::{equal, not_equal}

///|
pub extend CacheError with @debug.Debug::{to_repr}

///|
pub extend CacheLimits with Eq::{equal, not_equal}

///|
pub extend CacheLimits with @debug.Debug::{to_repr}

///|
pub extend CacheControl with Eq::{equal, not_equal}

///|
pub extend CacheControl with @debug.Debug::{to_repr}

///|
pub extend CacheStoreOutcome with Eq::{equal, not_equal}

///|
pub extend CacheStoreOutcome with @debug.Debug::{to_repr}

///|
pub extend CacheCondition with Eq::{equal, not_equal}

///|
pub extend CacheCondition with @debug.Debug::{to_repr}
