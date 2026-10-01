///|
pub extend AuthError with Eq::{equal, not_equal}

///|
pub extend AuthError with @debug.Debug::{to_repr}

///|
pub extend AuthLimits with Eq::{equal, not_equal}

///|
pub extend AuthLimits with @debug.Debug::{to_repr}

///|
pub extend DigestAlgorithm with Eq::{equal, not_equal}

///|
pub extend DigestAlgorithm with @debug.Debug::{to_repr}

///|
pub extend DigestQop with Eq::{equal, not_equal}

///|
pub extend DigestQop with @debug.Debug::{to_repr}

///|
pub extend DigestPolicy with Eq::{equal, not_equal}

///|
pub extend DigestPolicy with @debug.Debug::{to_repr}
