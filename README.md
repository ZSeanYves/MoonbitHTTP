# ZSeanYves/MoonbitHTTP

MoonbitHTTP 0.6.0 is a transport-independent, streaming HTTP protocol library
for MoonBit. Its codecs are pure incremental state machines that build on all
four stable backends. Async connection drivers use
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
| `service` | Scoped streaming HTTP/1, HTTP/2 and auto-detect servers plus HTTP/1 and HTTP/2 clients |
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

## Verification

```bash
moon fmt --check
moon check --target all --deny-warn --warn-list +73
moon test --target all --deny-warn --warn-list +73
moon bench --build-only --target native --deny-warn --warn-list +73
```

See the [maintenance implementation report](./docs/maintenance-plan.md) for
the current architecture, protocol coverage, and verification baseline.

## License

Apache License 2.0. See [LICENSE](./LICENSE).
