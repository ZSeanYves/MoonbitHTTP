///|
pub extend EmptyBody with Body::{next_frame, size_hint, cancel}

///|
pub extend FullBody with Body::{next_frame, size_hint, cancel}

///|
pub extend QueueBody with Body::{next_frame, size_hint, cancel}

///|
pub extend BodyError with Eq::{equal, not_equal}

///|
pub extend BodyError with @debug.Debug::{to_repr}

///|
pub extend BodyStream with Body::{next_frame, size_hint}

///|
pub extend BodyLimitExceeded with Eq::{equal, not_equal}

///|
pub extend BodyLimitExceeded with @debug.Debug::{to_repr}
