///|
pub extend ServiceConfigError with Eq::{equal, not_equal}

///|
pub extend ServiceConfigError with @debug.Debug::{to_repr}

///|
pub extend ClientConnectionPhase with Eq::{equal, not_equal}

///|
pub extend ClientConnectionPhase with @debug.Debug::{to_repr}

///|
pub extend ClientConnectionTimeout with Eq::{equal, not_equal}

///|
pub extend ClientConnectionTimeout with @debug.Debug::{to_repr}
