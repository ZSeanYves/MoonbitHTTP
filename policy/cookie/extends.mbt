///|
pub extend CookieError with Eq::{equal, not_equal}

///|
pub extend CookieError with @debug.Debug::{to_repr}

///|
pub extend CookieRejection with Eq::{equal, not_equal}

///|
pub extend CookieRejection with @debug.Debug::{to_repr}

///|
pub extend CookieStoreOutcome with Eq::{equal, not_equal}

///|
pub extend CookieStoreOutcome with @debug.Debug::{to_repr}

///|
pub extend CookieSameSite with Eq::{equal, not_equal}

///|
pub extend CookieSameSite with @debug.Debug::{to_repr}

///|
pub extend CookieApi with Eq::{equal, not_equal}

///|
pub extend CookieApi with @debug.Debug::{to_repr}

///|
pub extend CookieContext with Eq::{equal, not_equal}

///|
pub extend CookieContext with @debug.Debug::{to_repr}

///|
pub extend CookieLimits with Eq::{equal, not_equal}

///|
pub extend CookieLimits with @debug.Debug::{to_repr}

///|
pub extend DomainError with Eq::{equal, not_equal}

///|
pub extend DomainError with @debug.Debug::{to_repr}
