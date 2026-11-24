# Streaming HTTP protocol suite for MoonBit

MoonbitHTTP provides portable HTTP/1.1, HTTP/2, HTTP/3, QUIC, TLS, streaming
body, and policy building blocks for MoonBit. `0.7.0` is a breaking alpha
architecture line; APIs may change before `1.0.0`.

HTTP codecs and connection state machines consume bytes and events. The QUIC
driver also provides adapters for a caller-supplied datagram socket. Native
QUIC packet protection uses OpenSSL 3 EVP, and the Native TLS handshake for
HTTP/3 requires OpenSSL 3.5 or later. Wasm and JS packet protection uses the
experimental portable crypto implementation.

## Installation

Install the published `0.7.0` alpha from the MoonBit project root.

```bash
moon add ZSeanYves/MoonbitHTTP@0.7.0
```

For the current source checkout, clone the repository and use its pinned
MoonBit toolchain; the repository's CI and release checks are the authoritative
way to validate a checkout before publication.

Package READMEs describe usage. The generated `pkg.generated.mbti` files list the public APIs.

The source checkout adds `with_http2_pool` for pooled streaming requests to
direct HTTP/2 origins. Native servers can use `NativeTcpListener::bind_http_tls`
to serve HTTP/1.1 and HTTP/2 on the same TLS listener.
[Client usage](application/client/README.md) · [Server usage](adapter/native/server/README.md)

## Packages

- `core/types`, `core/body`, `core/codec`: HTTP values, streaming bodies,
  cancellation, backpressure, and bounded byte codecs.
- `protocol/http1`, `protocol/http2`, `protocol/http3`, `protocol/quic`,
  `protocol/tls`: incremental framing and protocol state machines. These
  packages do not open sockets.
- `runtime/transport`, `runtime/service`, `runtime/detection`: host capability
  contracts, protocol selection, HTTP/1 and HTTP/2 service lifecycle, h2c, and scoped HTTP/3 datagram I/O.
- `application/client`, `application/server`: request orchestration, pooling,
  and server dispatch contracts.
- `policy/auth`, `policy/cache`, `policy/cookie`, `policy/content_coding`:
  opt-in HTTP policies.
- `adapter/native/*`: Native TCP/UDP, resolver, clock, OpenSSL stream TLS and
  QUIC TLS adapters.
- `adapter/callback`: callback-to-async `BinaryReader`/`BinaryWriter` integration for a host
  runtime.

### Naming conventions

Each public operation has one canonical name within its package. When an API moves or is renamed, update its callers and record the change in the changelog.

- Package paths use lowercase names by responsibility, such as `protocol/http2` and `adapter/callback`. Source files use `snake_case` and name the feature they contain, such as `tcp_listener.mbt`. Related tests use `_test.mbt` or `_wbtest.mbt`.
- Functions and methods use `snake_case`. Use a verb for an action (`send`), a question for a predicate (`is_idle`), and `with_…` when a callback owns a resource for a limited scope.
- Types and traits use `PascalCase`. Name a concrete type for what it owns (`Http2ClientConnection`) and a trait for the capability its caller needs (`NameResolver`). Across protocols, use `Http1`, `Http2` and `Http3` in type names and `http1`, `http2` and `http3` in function names. Keep wire spellings such as `h2c` and the ALPN identifier `h2`.

## Features

- [x] **[portable] HTTP/1.1** — incremental messages, framing, trailers,
  validation, and service/client integration.
- [x] **[portable] HTTP/2** — frames, HPACK, SETTINGS, GOAWAY/RST, multiplexed
  streams, flow control, h2c, and lifecycle-aware services.
- [x] **[portable] HTTP/3 and QUIC engines** — QPACK, critical streams,
  streaming client/server sessions, packet protection, recovery, CID and path state.
- [x] **[portable] Shared HTTP values** — `Request`, `Response`, `HeaderMap`,
  URI, authority, endpoint, limits, and typed errors.
- [x] **[portable] Streaming bodies** — bounded queues, backpressure,
  cancellation, trailers, and explicit body ownership.
- [x] **[portable] Optional policies** — authentication, cookies, cache
  decisions, redirects, retries, and bounded content-coding transforms.
- [x] **[host] Capability injection** — stream/datagram I/O, resolver, clock,
  entropy, TLS, and `NetworkPolicy` are explicit inputs.
- [x] **[host] Callback integration** — `adapter/callback` adapts host callbacks to
  async `BinaryReader`/`BinaryWriter` capabilities.
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
| HTTP/1.1 and HTTP/2 service interfaces | Available through an adapter | Wasm with host capabilities. Wasm-GC compile only | Available with host capabilities |
| Native TCP/UDP/DNS/OpenSSL adapters | Supported | Unsupported | Unsupported |
| HTTP/3/QUIC protocol state | Streaming client sessions and supervised UDP listeners | Compile and use; host datagram/TLS required | Compile and use; host datagram/TLS required |
| HTTP/3 network TLS | OpenSSL 3.5+ QUIC TLS provider | Host supplied | Host supplied |
| Browser `fetch`/WebSocket integration | Not applicable | Not promised | Not promised |

“Compile and use” for a portable package does not grant network access. Wasm
and JavaScript consumers must provide the required host capabilities and must
not import `adapter/native/*`.

## Examples

The `streaming_client` example accepts `h1`, `h2` or `h3` and either `get` or `upload`. To fetch a page from a local HTTP/1.1 server, run `moon run examples/cmd/streaming_client --target native -- h1 get http://127.0.0.1:18080/`.

- [`examples/cmd/smoke_server`](examples/cmd/smoke_server/README.md) — bounded
  Native HTTP/1.1 and h2c service smoke fixture.
- [`examples/cmd/h3_smoke_server`](examples/cmd/h3_smoke_server/README.md) —
  uses the supervised UDP listener to serve HTTP/3 requests.
- [`examples/cmd/h3_smoke_client`](examples/cmd/h3_smoke_client/README.md) —
  opens two request streams on one authenticated HTTP/3 connection.

Run these fixtures through the repository runners described in their package
README files; they are verification programs, not deployment templates.

## Standards and scope

HTTP/1.1 and HTTP/2 have the broadest application coverage. HTTP/2 framing and
HPACK target [RFC 9113](https://www.rfc-editor.org/rfc/rfc9113) and
[RFC 7541](https://www.rfc-editor.org/rfc/rfc7541). The native HTTP/3 client accepts a numeric peer or a hostname with an explicit resolver and returns streaming responses. Use `with_http3_pool` for multiple HTTPS origins, or `with_http3_client_connection` for one authenticated connection. The native HTTP/3 listener accepts the same streaming request handler as HTTP/1 and HTTP/2. It routes connection IDs on one UDP socket, and its supervisor bounds concurrent handshakes and drains active peers on shutdown.

Native TLS and QUIC require an explicitly selected provider. Wasm and
JavaScript do not receive browser networking, DNS, UDP, or TLS automatically.
The async runtime is cooperative, so host capabilities and application
handlers must yield and keep cancellation cleanup bounded.

## Validation status

In a source checkout, run `moon run tests/run.mbtx -- blackbox native` for public API tests. Use `whitebox` for private unit tests, `integration` for component and socket tests, and `verify` to check that every case belongs to exactly one suite. The test directory includes a [guide to the suites](https://github.com/ZSeanYves/MoonbitHTTP/blob/main/tests/README.md).

The repository runs strict Native, Wasm, Wasm-GC, and JavaScript checks, tests,
architecture validation, Native TLS suites, HTTP/3/QUIC interoperability, and
controlled Native performance/reference runs in CI. These are bounded
development and loopback validations. They do not by themselves establish
public-network capacity, long-duration reliability, cross-platform deployment
coverage, or a complete independent security assessment.

See the [changelog](CHANGELOG.md) for changes by version.

## Caveats

- `0.7.0` is an alpha architecture line with breaking package paths.
- Native QUIC TLS requires OpenSSL 3.5 or newer.
- Browser fetch/WebSocket adapters and online OCSP retrieval are outside the current scope.
- A portable build proves compilation for a target; it does not prove that the
  target supplies a usable network implementation.

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
