///|
pub extend TransportOperation with Eq::{equal, not_equal}

///|
pub extend TransportOperation with @debug.Debug::{to_repr}

///|
pub extend Endpoint with Eq::{equal, not_equal}

///|
pub extend Endpoint with @debug.Debug::{to_repr}

///|
pub extend Endpoint with Compare::{compare, op_lt, op_le, op_ge, op_gt}

///|
pub extend Endpoint with Hash::{hash, hash_combine}

///|
pub extend EndpointError with Eq::{equal, not_equal}

///|
pub extend EndpointError with @debug.Debug::{to_repr}

///|
pub extend ConnectOptions with Eq::{equal, not_equal}

///|
pub extend ConnectOptions with @debug.Debug::{to_repr}

///|
pub extend ConnectOptionsError with Eq::{equal, not_equal}

///|
pub extend ConnectOptionsError with @debug.Debug::{to_repr}

///|
pub extend TransportError with Eq::{equal, not_equal}

///|
pub extend TransportError with @debug.Debug::{to_repr}

///|
pub extend Datagram with Eq::{equal, not_equal}

///|
pub extend Datagram with @debug.Debug::{to_repr}

///|
pub extend ResolveOptions with Eq::{equal, not_equal}

///|
pub extend ResolveOptions with @debug.Debug::{to_repr}

///|
pub extend IpAddress with Eq::{equal, not_equal}

///|
pub extend IpAddress with @debug.Debug::{to_repr}

///|
pub extend IpAddress with Compare::{compare, op_lt, op_le, op_ge, op_gt}

///|
pub extend StaticResolver with NameResolver::{resolve}

///|
pub extend PolicyOperation with Eq::{equal, not_equal}

///|
pub extend PolicyOperation with @debug.Debug::{to_repr}

///|
pub extend PolicyError with Eq::{equal, not_equal}

///|
pub extend PolicyError with @debug.Debug::{to_repr}

///|
pub extend AllowAllPolicy with NetworkPolicy::{authorize}

///|
pub extend DenyAllPolicy with NetworkPolicy::{authorize}

///|
pub extend EntropyError with Eq::{equal, not_equal}

///|
pub extend EntropyError with @debug.Debug::{to_repr}

///|
pub extend FixedClock with Eq::{equal, not_equal}

///|
pub extend FixedClock with @debug.Debug::{to_repr}

///|
pub extend FixedClock with Clock::{monotonic_millis, wall_clock_seconds}

///|
pub extend ZeroEntropy with Entropy::{fill}

///|
pub extend MemoryDatagramSocket with DatagramSocket::{send, receive, close}
