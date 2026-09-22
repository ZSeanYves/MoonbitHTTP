# ZSeanYves/MoonbitHTTP

MoonbitHTTP 0.6.0 is a transport-independent, streaming HTTP protocol library
for MoonBit. Its protocol codecs are pure incremental state machines; client,
server, policy, authentication, caching, and content-coding behavior live in
separate packages. Async connection drivers use
`moonbitlang/async/io.Reader` and `Writer` directly, so they work with TCP,
memory pipes, and callback-based runtimes.

## Packages

| Package | Responsibility |
| --- | --- |
| `types` | Multi-value headers, generic Request/Response, Method, Uri, Version, limits |
| `body` | Async Body trait, bounded BodyStream, Data/Trailers frames and SizeHint |
| `codec` | Protocol-independent incremental byte buffering and codec errors |
| `http1` | RFC 9110/9112 framing, streaming events, pipelining and encoding |
| `http2` | Frames, complete HPACK Huffman/dynamic table, streams and flow control |
| `http3` | HTTP/3 frame, settings, request-stream and QPACK state machines |
| `quic` | QUIC varint/frame/packet protection, recovery, paths and datagram driver contracts |
| `service` | Scoped streaming HTTP/1, HTTP/2 and auto-detect servers plus HTTP/1 and HTTP/2 clients |
| `client` | Bounded HTTP/1 pooling, proxy/CONNECT, redirect/retry, cookies, cache, auth and decoding policy |
| `server` | Listener contract, lifecycle supervisor, concurrency limits and redacted observer events |
| `cookie` / `cache` | Per-client cookie state and pluggable bounded RFC 9111 cache policy |
| `auth` / `content_coding` | Basic/Digest/Bearer challenge state and bounded gzip/deflate/Brotli decoding |
| `transport` / `tls` | Endpoint, resolver, clock, policy and TLS capability contracts |
| `client/native` / `server/native` / `transport/native` / `tls/native` | Native TCP, DNS, clock, UDP, TLS and listener adapters |
| `auto` | Prior knowledge, h2c and externally supplied ALPN selection |
| `uv_adapter` | Callback/uv-style I/O bridge to the official Reader/Writer traits |
| `test_support` | Fragmentation, fault injection and recording I/O fixtures |

## Interoperability

The native smoke server handles HTTP/1.1, HTTP/2 prior knowledge, and h2c on a
real TCP socket. Run the curl/nghttp2 checks with:

```bash
bash scripts/interoperability.sh
```

The service layer never collects request or response bodies implicitly. Server
handlers receive `Request[BodyStream]` and return `Response[B]` for any `B : Body`.
Use `ServerConfig.body_queue_capacity` to tune bounded backpressure and
`close_callback` to connect protocol shutdown to the transport adapter. HTTP/2
clients are scoped with `with_h2_client_connection`; the callback owns the
client and must consume response bodies before it returns.

The native TLS adapter deliberately fails closed for custom trust-anchor bytes,
client certificate/key bytes, server handshakes, and ALPN offers other than
`http/1.1` because the current host TLS API does not expose those capabilities.
The portable TLS facade and QUIC/HTTP/3 state machines are available for injected
providers, but native HTTP/3 interoperability and certificate-path validation
remain release gates in the production roadmap.

## Verification

```bash
moon fmt --check
moon check --target all --deny-warn --warn-list +73
moon test --target all --deny-warn --warn-list +73
moon bench --build-only --target native --deny-warn --warn-list +73
bash scripts/interoperability.sh
moon package --list
```

See the [maintenance implementation report](./docs/maintenance-plan.md) for
the current architecture, protocol coverage, and verification baseline. The
[release evidence record](./docs/release-evidence-2026-09-22.md) lists the exact
toolchain, test matrix, and artifact hash for the current worktree. See
[CHANGELOG.md](./CHANGELOG.md) for behavior changes and remaining release gates.

## License

Apache License 2.0. See [LICENSE](./LICENSE).
