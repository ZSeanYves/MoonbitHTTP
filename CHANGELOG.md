# Changelog

## Unreleased

### Breaking changes

- Custom stream adapters must implement `BinaryReader` and `BinaryWriter` from `moonbitlang/core/async/io`. The library now uses the async runtime bundled with MoonBit `0.10.22+124d61d05`.
- Custom QUIC transports must pass acknowledgements for FIN and reset frames to `acknowledge_stream_frame` so the peer can open new streams.

### Added

- HTTP/2 and HTTP/3 clients can pool connections by origin. Both support streaming uploads and responses, request cancellation and configurable connection limits.
- Native servers can serve HTTP/1.1 and HTTP/2 on one TLS listener using ALPN. HTTP/3 servers can serve the same streaming handler on a shared UDP socket.
- The pooled HTTP/1.1 client accepts streaming request bodies and supports `Expect: 100-continue`.

### Changed

- The callback transport is available at `adapter/callback`. Service clients for a single connection are now named `Http1ClientConnection`, `Http2ClientConnection` and `Http3ClientConnection`. Use `with_http2_pool` or `with_http3_pool` for pooled requests and `with_http3_client_connection` for one native HTTP/3 connection. The earlier import and API names remain available.
- Published packages omit test fixtures, test helpers and the native OCSP/CRL fixture signer.
- Native QUIC uses OpenSSL 3 for packet protection, key derivation and Retry integrity. The native HTTP/3 handshake requires OpenSSL 3.5 or later.
- Native DNS lookups return multiple addresses per family in system order. Callers can time out while a system lookup is still running.

### Fixed

- HTTP/1.1 clients can receive a final response during an upload. They cancel the upload and retire the connection if the request was only partially written.
- HTTP/2 and HTTP/3 servers send GOAWAY on shutdown, let accepted requests finish and refuse new streams. Idle connections close promptly.
- QUIC honors the negotiated idle timeout, continues loss recovery when packet tracking is full and keeps HTTP/3 streams alive when connection IDs rotate. A stateless reset releases the failed connection from the pool.
- A cache-enabled client returns 504 for an unsatisfied `only-if-cached` request, including when a stored response needs revalidation.
- Servers return 417 for unsupported expectations. HTTP/1 and HTTP/2 skip the response body for HEAD, 204 and 304.

## 0.7.0 — 2026-10-07

- **Breaking** — Imports moved under `core/`, `protocol/`, `runtime/`, `application/`, `policy/` and `adapter/`. The legacy `io` facade and the standalone non-pooled HTTP/1 round-tripper were removed.
- Added HTTP/3 framing, QPACK and QUIC packet processing, flow control and loss recovery.
- Added native TCP, UDP, DNS and OpenSSL adapters, including mutual TLS, offline CRL checks and stapled OCSP validation.
- Added opt-in authentication, cookie, cache and content-coding policies.
- Fixed HTTP/2 receive-credit accounting and cleanup of cancelled bodies and h2c connections.

## 0.6.0

- Added `with_h2_client_connection` to scope multiplexed requests and close the connection on exit. Services can configure body queue capacity and supply a transport close callback.

## 0.5.0

- Added `BodyStream` for streaming HTTP/1 and HTTP/2 requests and responses, with bounded buffering and trailers.
- Added a streaming HTTP/2 client alongside the HTTP/1 client.

## 0.4.0

- Moved the HTTP types, codecs and services out of `src/` into root-level packages.
- Added incremental HTTP/1.1 and HTTP/2 codecs, HPACK support and HTTP/2 protocol selection through prior knowledge or h2c upgrade.

## 0.1.0

- Introduced the MoonBit module, HTTP request and response types, and an HTTP/1.1 parser and encoder.
