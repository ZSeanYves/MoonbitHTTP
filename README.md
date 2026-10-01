# ZSeanYves/MoonbitHTTP

MoonbitHTTP is a streaming HTTP protocol library for MoonBit. The current
`0.7.0` development line deliberately breaks the 0.6 API. It separates
protocol codecs, connection state and I/O drivers, with explicit host capabilities.
Production release gates remain defined in the
[roadmap](docs/production-http-roadmap.zh-CN.md).

[中文说明](README_zh.md) · [Architecture](docs/v1-architecture.md) ·
[Actual dependency graph](docs/v1-dependencies.md) · [Validation](docs/v1-testing.md)

See the [0.6 to v1 migration guide](docs/v1-migration.md) for renamed types,
required constructor arguments and source navigation.

## Packages

| Package | Responsibility |
| --- | --- |
| `types` | Requests, responses, headers, URI, authority, IP addresses, endpoints and limits |
| `body` | Body producers, bounded streams, backpressure, cancellation and completion |
| `codec` | Incremental buffers and the shared HPACK/QPACK Huffman codec |
| `transport` | Stream, datagram, resolver, policy, clock, entropy and TLS capability contracts |
| `http1` | Start lines, fields, framing, incremental decoders and body encoder |
| `http2` | Frames, HPACK, connection/stream state, settings and flow control |
| `quic` | Packets, frames, transport parameters, connection/path state, recovery and TLS/datagram drivers |
| `http3` | HTTP/3 frames, QPACK, fields, control streams and request stream driver |
| `tls` | Pure TLS handshake framing and QUIC packet/key derivation primitives |
| `service` | HTTP/1 and HTTP/2 connection drivers and scoped lifecycle |
| `client` / `server` | Request policy, pooling, listeners and lifecycle supervision |
| `auth` / `cookie` / `cache` / `content_coding` | Optional application policies |
| `*/native` | Native TCP, UDP, DNS, clock, OpenSSL TLS and listener adapters |
| `auto` / `uv_adapter` | Protocol selection and callback I/O integration |
| `test_support` | Fragmentation, faults, recording I/O, deterministic clocks and datagrams |

## Constructing clients

Use `Http1Client::from_capabilities(connector, resolver, tls_provider, policy,
clock)` from `client`. The Native factory is
`client/native.new_http1_client(resolver, policy, clock, tls_provider)`.
Callers choose every capability explicitly. Resolver results are authorized
again before numeric connections; low-level connectors do not perform hidden DNS.
The callback executor accepts a missing resolver only for numeric endpoints.

The policy client aggregates byte bodies under explicit limits. Streaming
users work with the service drivers and `BodyStream`. Server handlers receive
`Request[BodyStream]` and return `Response[B]` for `B : Body`; service drivers
do not implicitly collect bodies. The connection scope owns cancellation and
shutdown. HTTP/2 uses `with_h2_client_connection`; consume required response
bodies inside its callback.

Native TLS uses OpenSSL 3 for custom CA bytes, client/server PEM credentials,
certificate identity/validity verification and ALPN. QUIC TLS requires OpenSSL
**3.5 or newer**. See [Native TLS](tls/native/README.md) and [QUIC TLS](tls/QUIC.md)
for runtime requirements and supported algorithms. The adapter has Linux,
macOS and Windows dynamic-loader paths; the CI matrix runs the certificate and
identity suite on all three platforms. Portable codecs compile on Native,
Wasm, Wasm-GC and JS, while platform evidence remains part of the release gate.

## Verification

Run Moon commands serially; they share a build lock.

```sh
moon fmt --check
moon run tools/check_architecture.mbtx
moon check --target all --deny-warn --warn-list +73
moon build --target all --deny-warn --warn-list +73
moon test --target all --deny-warn --warn-list +73
moon info --target all
moon run tools/interoperability.mbtx
moon run tools/benchmarks.mbtx
```

The socket interoperability tool requires curl, wget and nghttp2. It tests
HTTP/1.1 GET/POST, HTTP/2 prior knowledge and h2c against a freshly built server.
Benchmarks execute actual release binaries and save their measurements.
Neither test counts nor loopback throughput prove production readiness.

`tools/release_evidence.mbtx` refuses a dirty checkout and verifies the archive
against tracked Git blobs before recording release evidence. Do not treat
`moon package --list` as read-only: it also rewrites the package archive.
Historical 0.6 results are preserved in the
[frozen baseline](docs/v1-baseline-2026-09-29.md).

## License

Apache License 2.0. See [LICENSE](LICENSE).
