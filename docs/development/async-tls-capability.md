# Async TLS capability matrix

This matrix records the decision for `moonbitlang/async@0.22.4`. It is a
compatibility audit, not a promise that every async TLS API is a drop-in
replacement for MoonbitHTTP's provider.

| `TlsOptions` or behavior | Public async TLS API | MoonbitHTTP decision |
| --- | --- | --- |
| System trust roots | Client API supports `SystemRoot` | Reusable in isolation, but not sufficient for `TlsProvider` equivalence |
| Explicit no verification | Client API supports `NoVerification` | Test-only capability; never a production default |
| SNI and hostname | Client API accepts `host` and sets SNI | Reusable only after metadata and error mapping are equivalent |
| ALPN | No public ALPN configuration or selected-protocol result | Must remain in Native provider |
| Negotiated TLS version | No public result | Must remain in Native provider |
| Negotiated cipher | No public result | Must remain in Native provider |
| TLS version range | No public configuration | Must remain in Native provider |
| In-memory trust anchors | Public API accepts a PEM file path only | Must remain in Native provider; no temporary-file fallback |
| In-memory client identity | No public client credential configuration | Must remain in Native provider |
| In-memory server identity | Server API uses credential files and is not equivalent to current options | Must remain in Native provider |
| mTLS policy | No complete public mapping | Must remain in Native provider |
| CRL | No public configuration | Must remain in Native provider |
| OCSP stapling | No public configuration or result | Must remain in Native provider |
| QUIC CRYPTO and traffic secrets | Stream TLS API has no such callbacks | Keep `QuicTlsProvider` and Native QUIC provider |
| Cancellation, close and error taxonomy | Different public error and ownership model | Requires dedicated differential tests before any switch |

## Current implementation decision

`NativeStreamIo` is a reusable Native-only Reader/Writer bridge. The
`AsyncStreamTlsProvider` is retained as an opt-in, fail-closed compatibility
spike: because async@0.22.4 cannot expose the metadata required by
`SecureConnection`, it currently returns `Unsupported` before starting a
handshake. This prevents an apparent success from reporting fabricated TLS
version, cipher or ALPN data.

The existing `NativeTlsProvider` remains the only production stream-TLS
implementation. It continues to provide the current ALPN, in-memory
credentials, trust-anchor, CRL, OCSP, mTLS, TLS-version and server semantics.

## A/B gate

An A/B run may promote the async implementation only after the async public
API can represent every supported `TlsOptions` field and expose equivalent
negotiated metadata. The test matrix must then compare handshake, identity,
ALPN, credentials, revocation, partial I/O, EOF, cancellation, timeout,
close ordering, error taxonomy, HTTP/1, HTTP/2 and server lifecycle. Until
all rows pass on the supported Native platforms and remote CI is green, the
Native provider must not be switched or deleted.
