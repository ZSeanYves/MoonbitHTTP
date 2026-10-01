///|
pub extend ServerState with Eq::{equal, not_equal}

///|
pub extend ServerState with @debug.Debug::{to_repr}

///|
pub extend ServerPhase with Eq::{equal, not_equal}

///|
pub extend ServerPhase with @debug.Debug::{to_repr}

///|
pub extend ServerError with Eq::{equal, not_equal}

///|
pub extend ServerError with @debug.Debug::{to_repr}

///|
pub extend ServerLimits with Eq::{equal, not_equal}

///|
pub extend ServerLimits with @debug.Debug::{to_repr}

///|
pub extend ServerEvent with Eq::{equal, not_equal}

///|
pub extend ServerEvent with @debug.Debug::{to_repr}

///|
pub extend ServerMetrics with Eq::{equal, not_equal}

///|
pub extend ServerMetrics with @debug.Debug::{to_repr}
