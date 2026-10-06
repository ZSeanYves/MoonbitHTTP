# Async reuse boundary

MoonbitHTTP uses `moonbitlang/async@0.22.4` as its runtime substrate. Task
groups, cancellation, timeouts, locks, queues, `Reader`/`Writer`, TCP, UDP and
address lookup are reused through thin Native or host adapters. The portable
protocol packages continue to depend only on MoonbitHTTP capability contracts.

## Stream TLS boundary

The capability review in the [async TLS capability matrix](async-tls-capability.md)
found that async@0.22.4 cannot represent the complete `TlsOptions` and
`SecureConnection` contract. Its stream TLS API lacks negotiated metadata,
in-memory credentials, revocation controls and the required server semantics.
MoonbitHTTP therefore does not ship an async stream TLS provider or a
fail-closed placeholder. `NativeTlsProvider` is the single ordinary stream-TLS
implementation, with no runtime fallback or second public provider.

This decision can be revisited only after an async release exposes every
required security option and metadata field. Until then, reusing individual
async TLS calls would silently narrow the existing contract, so the project
continues to reuse async for its runtime substrate while retaining its Native
OpenSSL stream-TLS boundary.

## QUIC TLS boundary

The async stream TLS API does not expose QUIC CRYPTO input/output, encryption
levels or traffic-secret callbacks. The Native OpenSSL 3.5+ QUIC provider
therefore remains separate and continues to implement the
`runtime/transport.QuicTlsProvider` contract. HTTP/1, HTTP/2, HTTP/3, HPACK,
QPACK and QUIC state machines remain MoonbitHTTP-owned.
