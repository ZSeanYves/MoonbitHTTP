# Async reuse boundary

MoonbitHTTP uses the experimental `moonbitlang/core/async` packages bundled with
the pinned compiler. Task groups, cancellation, timeouts, locks, queues,
`BinaryReader`/`BinaryWriter`, TCP, UDP and
address lookup are reused through thin Native or host adapters. The portable
protocol packages continue to depend only on MoonbitHTTP capability contracts.

Standalone Native development scripts pin `moonbitlang/async@0.22.10` for
their process and filesystem APIs. These scripts build separately from the library.

## Stream TLS boundary

The capability review in the [async TLS capability matrix](async-tls-capability.md)
records why the standalone async TLS API could not represent the complete `TlsOptions` and
`SecureConnection` contract. The bundled core stream TLS API also lacks negotiated metadata,
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
