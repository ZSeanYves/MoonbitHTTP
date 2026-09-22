///|
pub extend ClientPhase with Eq::{equal, not_equal}

///|
pub extend ClientPhase with @debug.Debug::{to_repr}

///|
pub extend RedirectError with Eq::{equal, not_equal}

///|
pub extend RedirectError with @debug.Debug::{to_repr}

///|
pub extend RetryError with Eq::{equal, not_equal}

///|
pub extend RetryError with @debug.Debug::{to_repr}

///|
pub extend ClientError with Eq::{equal, not_equal}

///|
pub extend ClientError with @debug.Debug::{to_repr}

///|
pub extend ClientEndpoint with Eq::{equal, not_equal}

///|
pub extend ClientEndpoint with @debug.Debug::{to_repr}

///|
pub extend ClientTimeouts with Eq::{equal, not_equal}

///|
pub extend ClientTimeouts with @debug.Debug::{to_repr}

///|
pub extend RedirectPolicy with Eq::{equal, not_equal}

///|
pub extend RedirectPolicy with @debug.Debug::{to_repr}

///|
pub extend RetryMode with Eq::{equal, not_equal}

///|
pub extend RetryMode with @debug.Debug::{to_repr}

///|
pub extend RetryPolicy with Eq::{equal, not_equal}

///|
pub extend RetryPolicy with @debug.Debug::{to_repr}

///|
pub extend BodyReplayability with Eq::{equal, not_equal}

///|
pub extend BodyReplayability with @debug.Debug::{to_repr}

///|
pub extend RequestOptions with Eq::{equal, not_equal}

///|
pub extend RequestOptions with @debug.Debug::{to_repr}

///|
pub extend ProxyMode with Eq::{equal, not_equal}

///|
pub extend ProxyMode with @debug.Debug::{to_repr}

///|
pub extend ProxyConfig with Eq::{equal, not_equal}

///|
pub extend ProxyConfig with @debug.Debug::{to_repr}

///|
pub extend RetryCause with Eq::{equal, not_equal}

///|
pub extend RetryCause with @debug.Debug::{to_repr}

///|
pub extend RetryDecision with Eq::{equal, not_equal}

///|
pub extend RetryDecision with @debug.Debug::{to_repr}

///|
pub extend ClientProtocol with Eq::{equal, not_equal}

///|
pub extend ClientProtocol with @debug.Debug::{to_repr}

///|
pub extend ClientProtocol with Compare::{compare, op_lt, op_le, op_ge, op_gt}

///|
pub extend ClientProtocol with Hash::{hash, hash_combine}

///|
pub extend ConnectionKey with Eq::{equal, not_equal}

///|
pub extend ConnectionKey with @debug.Debug::{to_repr}

///|
pub extend ConnectionKey with Compare::{compare, op_lt, op_le, op_ge, op_gt}

///|
pub extend ConnectionKey with Hash::{hash, hash_combine}

///|
pub extend PoolError with Eq::{equal, not_equal}

///|
pub extend PoolError with @debug.Debug::{to_repr}

///|
pub extend PoolLimits with Eq::{equal, not_equal}

///|
pub extend PoolLimits with @debug.Debug::{to_repr}

///|
pub extend PoolAcquire with Eq::{equal, not_equal}

///|
pub extend PoolAcquire with @debug.Debug::{to_repr}

///|
pub extend PoolLease with Eq::{equal, not_equal}

///|
pub extend PoolLease with @debug.Debug::{to_repr}

///|
pub extend ClosureRoundTripper with ByteRoundTripper::{execute}

///|
pub extend Http1RoundTripper with ByteRoundTripper::{execute}

///|
pub extend Http1PooledRoundTripper with StreamingRoundTripper::{execute_stream}

///|
pub extend Http1PooledRoundTripper with ByteRoundTripper::{execute}
