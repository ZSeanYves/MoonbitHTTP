# ZSeanYves/MoonbitHTTP

MoonbitHTTP is a streaming HTTP foundation for MoonBit. Version `0.7.0` is
the breaking v1 architecture line and an alpha development release.

## Features

- **[portable] HTTP/1.1** — incremental request and response codecs, framing,
  trailers, validation, and async service/client integration.
- **[portable] HTTP/2** — frames, HPACK, SETTINGS, GOAWAY/RST, multiplexed
  streams, bounded flow control, h2c upgrade, and async service drivers.
- **[portable] HTTP/3 and QUIC engines** — QPACK, critical streams, request
  stream state, packet protection, recovery, path validation, and transport
  state. These are protocol engines and driver APIs; a general HTTP/3
  application service is not provided yet.
- **[portable] Shared HTTP data types** — validated `Request`, `Response`, `HeaderMap`,
  URI and authority values, endpoints, limits, and typed errors.
- **[portable] Streaming bodies** — bounded queues, backpressure, cancellation, trailers,
  and explicit ownership for request and response bodies.
- **[portable] Optional policies** — authentication, cookies, cache decisions, redirects,
  retries, and bounded content-coding transforms.
- **[host] Explicit capabilities** — stream and datagram I/O, name resolution, clock,
  entropy, TLS, and `NetworkPolicy` are injected by the host. Protocol code
  never creates sockets or performs hidden DNS resolution.
- **[native] Native adapters** — TCP/UDP, resolver, clock, and OpenSSL-backed stream and
  QUIC TLS providers, plus Native client/server wiring.
- **[host] Callback integration** — `adapter/uv` bridges host callbacks to async
  `Reader`/`Writer` capabilities without selecting a socket or TLS backend.
- **[driver-level] HTTP/3/QUIC smoke and interop** — Native loopback and
  independent-driver checks exercise the protocol boundary; they do not imply a
  generic HTTP/3 application service.

## Target support

| Capability | Native | Wasm / Wasm-GC | JavaScript |
| --- | --- | --- | --- |
| `core/*`, `protocol/*`, `runtime/*`, `application/*`, `policy/*` | Compiles and runs with injected capabilities | Compiles and runs with host capabilities | Compiles and runs with host capabilities |
| HTTP/1 and HTTP/2 service interfaces | Available; network comes from an adapter | Available; network must be injected | Available; network must be injected |
| Native TCP/UDP/DNS/OpenSSL | Supported | Unsupported | Unsupported |
| HTTP/3/QUIC protocol state | Compiles; Native driver/TLS fixtures are available | Compiles; datagram and QUIC TLS come from the host | Compiles; datagram and QUIC TLS come from the host |
| HTTP/3 network TLS | Native OpenSSL; QUIC TLS requires OpenSSL 3.5+ | Host provided | Host provided |
| Browser fetch/WebSocket | Not applicable | Not promised | Not promised |

“Portable compilation” means the package builds for the target. Network
features still depend on the capabilities supplied by the host. Wasm and JS
builds must not import `adapter/native/*`; browser APIs, DNS, UDP, and TLS are
not assumed automatically.

## Packages

- **`core/*`** — protocol-independent types, bounded codec primitives, and
  streaming body contracts.
- **`protocol/*`** — HTTP/1.1, HTTP/2, HTTP/3, QUIC, and portable TLS state.
- **`runtime/*`** — capability contracts, protocol detection, and HTTP/1/H2
  service lifecycle, including h2c.
- **`application/*`** — client policy/pooling and server dispatch contracts.
  The concrete Native convenience client currently targets HTTP/1.1.
- **`policy/*`** — opt-in authentication, cache, cookie, and content-coding
  policy packages.
- **`adapter/native/*`** — Native socket, resolver, clock, and OpenSSL
  providers.
- **`adapter/uv`** — callback-to-async I/O bridge for a host runtime.

See the [package map](docs/concepts/packages.md) and [architecture
description](docs/concepts/architecture.md) for ownership and dependency
boundaries.

## Scope and limits

HTTP/1.1 and HTTP/2 currently have the broadest application coverage. The
HTTP/3 and QUIC layers expose portable codecs, state machines, and driver
actions; the current service layer does not silently turn them into a complete
HTTP/3 client or server. Native QUIC TLS uses the OpenSSL provider and requires
OpenSSL 3.5 or newer.

Native TLS supports explicit trust anchors, certificate identity checks, mTLS,
offline CRL checking, and stapled OCSP validation. Online OCSP retrieval and a
Native-style revocation provider for Wasm are outside this release.

The async runtime is cooperative. Application handlers and host capability
implementations must yield and keep protected cleanup bounded for cancellation
and shutdown to complete.

This is a well-tested development foundation, not a production-readiness or
standard-library compatibility claim. Local and loopback interoperability,
controlled Native performance runs, and targeted security regressions describe
their stated environments only; they do not establish public-network,
cross-platform, long-duration, or complete independent security coverage.
Known findings from the current remediation index have targeted fixes and
regressions; three candidate-review paths remain open for disposition, and
historical deep-scan coverage remains partial.

## Validation and next steps

- [Getting started](docs/guide/getting-started.md) — construct a client with
  explicit capabilities.
- [Architecture](docs/concepts/architecture.md) — dependency and state-machine
  boundaries.
- [Validation facts](docs/release/current.md) — current evidence and remaining
  release work.
- [Release gates](docs/release/gates.md) — the conditions for a production
  release.
- [Performance method](docs/development/performance.md) — controlled Native
  regressions and the separate Go `net/http` H1/H2 reference harness.
- [Changelog](CHANGELOG.md) — versioned behavior and API changes.

The canonical package paths are listed in the [package map](docs/concepts/packages.md).
Moving a package changes its import identity and is a breaking change during
the `0.7.0` alpha line.

## License

Apache License 2.0. See [LICENSE](LICENSE).
