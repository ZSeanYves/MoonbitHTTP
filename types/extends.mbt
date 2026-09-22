///|
pub extend HeaderError with Eq::{equal, not_equal}

///|
pub extend HeaderError with @debug.Debug::{to_repr}

///|
pub extend HeaderName with Eq::{equal, not_equal}

///|
pub extend HeaderName with @debug.Debug::{to_repr}

///|
pub extend HeaderName with Compare::{compare, op_lt, op_le, op_ge, op_gt}

///|
pub extend HeaderName with Hash::{hash, hash_combine}

///|
pub extend HeaderValue with Eq::{equal, not_equal}

///|
pub extend HeaderValue with @debug.Debug::{to_repr}

///|
pub extend HeaderField with Eq::{equal, not_equal}

///|
pub extend HeaderField with @debug.Debug::{to_repr}

///|
pub extend HttpDateError with Eq::{equal, not_equal}

///|
pub extend HttpDateError with @debug.Debug::{to_repr}

///|
pub extend HttpDate with Eq::{equal, not_equal}

///|
pub extend HttpDate with @debug.Debug::{to_repr}

///|
pub extend HttpDate with Compare::{compare, op_lt, op_le, op_ge, op_gt}

///|
pub extend Limits with Eq::{equal, not_equal}

///|
pub extend Limits with @debug.Debug::{to_repr}

///|
pub extend LimitsError with Eq::{equal, not_equal}

///|
pub extend LimitsError with @debug.Debug::{to_repr}

///|
pub extend Method with Eq::{equal, not_equal}

///|
pub extend Method with @debug.Debug::{to_repr}

///|
pub extend MethodError with Eq::{equal, not_equal}

///|
pub extend MethodError with @debug.Debug::{to_repr}

///|
pub extend Version with Eq::{equal, not_equal}

///|
pub extend Version with @debug.Debug::{to_repr}

///|
pub extend AuthorityError with Eq::{equal, not_equal}

///|
pub extend AuthorityError with @debug.Debug::{to_repr}

///|
pub extend Authority with Eq::{equal, not_equal}

///|
pub extend Authority with @debug.Debug::{to_repr}

///|
pub extend UriForm with Eq::{equal, not_equal}

///|
pub extend UriForm with @debug.Debug::{to_repr}

///|
pub extend Uri with Eq::{equal, not_equal}

///|
pub extend Uri with @debug.Debug::{to_repr}

///|
pub extend UriError with Eq::{equal, not_equal}

///|
pub extend UriError with @debug.Debug::{to_repr}
