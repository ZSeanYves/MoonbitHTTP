# Async reuse boundary

MoonbitHTTP uses `moonbitlang/async@0.22.4` as its runtime substrate. Task
groups, cancellation, timeouts, locks, queues, `Reader`/`Writer`, TCP, UDP and
address lookup are reused through thin Native or host adapters. The portable
protocol packages continue to depend only on MoonbitHTTP capability contracts.

## Stream TLS trial

`adapter/native/tls` contains an opt-in `AsyncStreamTlsProvider`. It currently
accepts only the option subset that the public async TLS API can represent
without silently dropping a MoonbitHTTP security setting. It is not the
default provider. Unsupported ALPN, credential, trust-anchor, TLS-version,
CRL, OCSP and server options fail closed with `Unsupported` or an options
error.

The existing Native provider remains the default until a complete A/B suite
proves equivalent behavior for handshake, identity, ALPN, credentials,
revocation, timeout, cancellation, close ordering and HTTP/1/HTTP/2
integration. After that evidence and a successful remote CI run, the old
ordinary stream implementation will be removed rather than retained as a
runtime fallback.

## QUIC TLS boundary

The async stream TLS API does not expose QUIC CRYPTO input/output, encryption
levels or traffic-secret callbacks. The Native OpenSSL 3.5+ QUIC provider
therefore remains separate and continues to implement the
`runtime/transport.QuicTlsProvider` contract. HTTP/1, HTTP/2, HTTP/3, HPACK,
QPACK and QUIC state machines remain MoonbitHTTP-owned.
