///|
pub extend ContentCoding with Eq::{equal, not_equal}

///|
pub extend ContentCoding with @debug.Debug::{to_repr}

///|
pub extend DecodeStatus with Eq::{equal, not_equal}

///|
pub extend DecodeStatus with @debug.Debug::{to_repr}

///|
pub extend DecodeStep with Eq::{equal, not_equal}

///|
pub extend DecodeStep with @debug.Debug::{to_repr}

///|
pub extend ContentCodingError with Eq::{equal, not_equal}

///|
pub extend ContentCodingError with @debug.Debug::{to_repr}

///|
pub extend ContentCodingLimits with Eq::{equal, not_equal}

///|
pub extend ContentCodingLimits with @debug.Debug::{to_repr}

///|
pub extend ContentDecodePoll with Eq::{equal, not_equal}

///|
pub extend ContentDecodePoll with @debug.Debug::{to_repr}

///|
pub extend DecodedBody with @body.Body::{next_frame, size_hint, cancel}
