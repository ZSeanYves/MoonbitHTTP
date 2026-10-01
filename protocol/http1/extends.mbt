///|
pub extend Http1Error with Eq::{equal, not_equal}

///|
pub extend Http1Error with @debug.Debug::{to_repr}

///|
pub extend BodyFraming with Eq::{equal, not_equal}

///|
pub extend BodyFraming with @debug.Debug::{to_repr}
