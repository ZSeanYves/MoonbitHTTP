///|
pub extend TransportOperation with Eq::{equal, not_equal}

///|
pub extend TransportOperation with @debug.Debug::{to_repr}

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
pub extend TlsOperation with Eq::{equal, not_equal}

///|
pub extend TlsOperation with @debug.Debug::{to_repr}

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

///|
pub extend QuicEncryptionLevel with Eq::{equal, not_equal}

///|
pub extend QuicEncryptionLevel with @debug.Debug::{to_repr}

///|
pub extend QuicSecretDirection with Eq::{equal, not_equal}

///|
pub extend QuicSecretDirection with @debug.Debug::{to_repr}

///|
pub extend QuicHandshakeMessage with Eq::{equal, not_equal}

///|
pub extend QuicHandshakeMessage with @debug.Debug::{to_repr}
