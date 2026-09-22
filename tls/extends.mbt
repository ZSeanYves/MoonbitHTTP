///|
pub extend TlsVersion with Eq::{equal, not_equal}

///|
pub extend TlsVersion with @debug.Debug::{to_repr}

///|
pub extend TlsOptionsError with Eq::{equal, not_equal}

///|
pub extend TlsOptionsError with @debug.Debug::{to_repr}

///|
pub extend TlsError with Eq::{equal, not_equal}

///|
pub extend TlsError with @debug.Debug::{to_repr}

///|
pub extend UnsupportedProvider with TlsProvider::{
  client_handshake,
  server_handshake,
}

///|
pub extend QuicTlsCipherSuite with Eq::{equal, not_equal}

///|
pub extend QuicTlsCipherSuite with @debug.Debug::{to_repr}
