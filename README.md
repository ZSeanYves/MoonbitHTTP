# Streaming HTTP protocol suite for MoonBit

MoonbitHTTP provides portable HTTP/1.1, HTTP/2, HTTP/3, QUIC, TLS, streaming
body, and policy building blocks for MoonBit. `0.7.0` is a breaking alpha
architecture line; APIs may change before `1.0.0`.

The protocol packages are capability-free state machines. Network access,
resolution, clocks, entropy, TLS, and authorization are supplied explicitly by
the host. This keeps portable packages usable on Native, Wasm, Wasm-GC, and
JavaScript without pretending that every target has the same network runtime.

## Installation

After the `0.7.0` package is published to Mooncakes, add it from a MoonBit
project root with:

```bash
moon add ZSeanYves/MoonbitHTTP@0.7.0
```

For the current source checkout, clone the repository and use its pinned
MoonBit toolchain; the repository's CI and release checks are the authoritative
way to validate a checkout before publication.

The package map and dependency boundaries are documented in
[`docs/concepts/packages.md`](docs/concepts/packages.md). Package-level API
documentation is kept beside each package; generated `.mbti` files remain the
canonical interface surface.

## Packages

- `core/types`, `core/body`, `core/codec`: HTTP values, streaming bodies,
  cancellation, backpressure, and bounded byte codecs.
- `protocol/http1`, `protocol/http2`, `protocol/http3`, `protocol/quic`,
  `protocol/tls`: incremental framing and protocol state machines. These
  packages do not open sockets.
- `runtime/transport`, `runtime/service`, `runtime/detection`: host capability
  contracts, protocol selection, HTTP/1 and HTTP/2 service lifecycle, and h2c.
- `application/client`, `application/server`: request orchestration, pooling,
  and server dispatch contracts.
- `policy/auth`, `policy/cache`, `policy/cookie`, `policy/content_coding`:
  opt-in HTTP policies.
- `adapter/native/*`: Native TCP/UDP, resolver, clock, OpenSSL stream TLS and
  QUIC TLS adapters.
- `adapter/uv`: callback-to-async `Reader`/`Writer` integration for a host
  runtime.

## Features

- [x] **[portable] HTTP/1.1** — incremental messages, framing, trailers,
  validation, and service/client integration.
- [x] **[portable] HTTP/2** — frames, HPACK, SETTINGS, GOAWAY/RST, multiplexed
  streams, flow control, h2c, and lifecycle-aware services.
- [x] **[portable] HTTP/3 and QUIC engines** — QPACK, critical streams,
  request-stream state, packet protection, recovery, CID and path state.
- [x] **[portable] Shared HTTP values** — `Request`, `Response`, `HeaderMap`,
  URI, authority, endpoint, limits, and typed errors.
- [x] **[portable] Streaming bodies** — bounded queues, backpressure,
  cancellation, trailers, and explicit body ownership.
- [x] **[portable] Optional policies** — authentication, cookies, cache
  decisions, redirects, retries, and bounded content-coding transforms.
- [x] **[host] Capability injection** — stream/datagram I/O, resolver, clock,
  entropy, TLS, and `NetworkPolicy` are explicit inputs.
- [x] **[host] Callback integration** — `adapter/uv` adapts host callbacks to
  async `Reader`/`Writer` capabilities.
- [x] **[native] TCP/UDP, DNS, and Native client/server adapters** — host
  sockets and resolver wiring; HTTP semantics and message behavior follow
  [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110) and HTTP/1.1 framing in
  [RFC 9112](https://www.rfc-editor.org/rfc/rfc9112).
- [x] **[native] OpenSSL stream TLS** — certificate identity and trust checks
  at the adapter boundary; TLS 1.3 behavior follows
  [RFC 8446](https://www.rfc-editor.org/rfc/rfc8446), with hostname identity
  rules from [RFC 6125](https://www.rfc-editor.org/rfc/rfc6125).
- [x] **[native] QUIC TLS provider** — OpenSSL 3.5+ supplies the Native QUIC
  TLS callbacks; the protocol boundary follows
  [RFC 9001](https://www.rfc-editor.org/rfc/rfc9001) and TLS 1.3
  [RFC 8446](https://www.rfc-editor.org/rfc/rfc8446).
- [x] **[native] HTTP/3/QUIC smoke and interop drivers** — Native loopback and
  independent-driver checks exercise [QUIC v1, RFC 9000](https://www.rfc-editor.org/rfc/rfc9000),
  [HTTP/3, RFC 9114](https://www.rfc-editor.org/rfc/rfc9114), and
  [QPACK, RFC 9204](https://www.rfc-editor.org/rfc/rfc9204).

The RFC links describe the protocol contracts this implementation targets.
They are not a claim that every optional extension or deployment profile is
implemented.

## Target support

| Capability | Native | Wasm / Wasm-GC | JavaScript |
| --- | --- | --- | --- |
| Core, codec, protocol, policy | Compile and use | Compile and use | Compile and use |
| HTTP/1.1 and HTTP/2 service interfaces | Available through an adapter | Available with host capabilities | Available with host capabilities |
| Native TCP/UDP/DNS/OpenSSL adapters | Supported | Unsupported | Unsupported |
| HTTP/3/QUIC protocol state | Compile and use; Native driver fixtures | Compile and use; host datagram/TLS required | Compile and use; host datagram/TLS required |
| HTTP/3 network TLS | OpenSSL 3.5+ QUIC TLS provider | Host supplied | Host supplied |
| Browser `fetch`/WebSocket integration | Not applicable | Not promised | Not promised |

“Compile and use” for a portable package does not grant network access. Wasm
and JavaScript consumers must provide the required host capabilities and must
not import `adapter/native/*`.

## Examples

- [`examples/cmd/smoke_server`](examples/cmd/smoke_server/README.md) — bounded
  Native HTTP/1.1 and h2c service smoke fixture.
- [`examples/cmd/h3_smoke_server`](examples/cmd/h3_smoke_server/README.md) —
  bounded Native HTTP/3 and QUIC loopback interoperability fixture.

Run these fixtures through the repository runners described in their package
README files; they are verification programs, not deployment templates.

## Standards and scope

HTTP/1.1 and HTTP/2 have the broadest application coverage. HTTP/2 framing and
HPACK target [RFC 9113](https://www.rfc-editor.org/rfc/rfc9113) and
[RFC 7541](https://www.rfc-editor.org/rfc/rfc7541). HTTP/3 and QUIC currently
provide protocol engines and driver actions; a general HTTP/3 client/server
service is not promised by this release.

Native TLS and QUIC require an explicitly selected provider. Wasm and
JavaScript do not receive browser networking, DNS, UDP, or TLS automatically.
The async runtime is cooperative, so host capabilities and application
handlers must yield and keep cancellation cleanup bounded.

## Validation status

The repository runs strict Native, Wasm, Wasm-GC, and JavaScript checks, tests,
architecture validation, Native TLS suites, HTTP/3/QUIC interoperability, and
controlled Native performance/reference runs in CI. These are bounded
development and loopback validations. They do not by themselves establish
public-network capacity, long-duration reliability, cross-platform deployment
coverage, or a complete independent security assessment.

See [`docs/release/current.md`](docs/release/current.md) for the current
evidence summary, [`docs/release/gates.md`](docs/release/gates.md) for release
conditions, and [`CHANGELOG.md`](CHANGELOG.md) for version history.

## Caveats

- `0.7.0` is an alpha architecture line with breaking package paths.
- Native QUIC TLS requires OpenSSL 3.5 or newer.
- HTTP/3 service orchestration, browser fetch/WebSocket adapters, and online
  OCSP retrieval are outside the current scope.
- A portable build proves compilation for a target; it does not prove that the
  target supplies a usable network implementation.

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
