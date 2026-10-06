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

The capability gap is intentionally resolved by omission: MoonbitHTTP does not
ship an `async/tls` stream facade, a `NativeStreamIo` bridge, or a public
provider that always returns `Unsupported`. Keeping that dead path in the
published package would create a second apparent implementation without
providing TLS semantics.

`NativeTlsProvider` is the only ordinary stream-TLS implementation. It continues
to provide the current ALPN, in-memory credentials, trust-anchor, CRL, OCSP,
mTLS, TLS-version and server semantics. `NativeQuicTlsProvider` remains a
separate QUIC provider because QUIC needs CRYPTO-level handshake bytes and
traffic-secret callbacks that stream TLS does not expose.

## A/B gate

An A/B migration may be considered only after the async public API can represent
every supported `TlsOptions` field and expose equivalent negotiated metadata.
The test matrix must compare handshake, identity, ALPN, credentials,
revocation, partial I/O, EOF, cancellation, timeout, close ordering, error
taxonomy, HTTP/1, HTTP/2 and server lifecycle. Until all rows pass on the
supported Native platforms and remote CI is green, `NativeTlsProvider` remains
the canonical implementation; no async facade is added merely to satisfy a
reuse target.
