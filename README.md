# ZSeanYves/http

[中文](README_zh.md)

A streaming HTTP library for MoonBit with support for HTTP/1.0, HTTP/1.1, HTTP/2, HTTP/3 and QUIC v1. Use the protocol codecs on their own, or integrate a client, connection pool or server listener into your application.

## Features

- **HTTP/1.0 and HTTP/1.1** — Incremental request and response parsing and encoding. HTTP/1.0 closes connections by default and supports explicit keep-alive. HTTP/1.1 adds chunked transfer and trailers.
- **HTTP/2** — Frame encoding and decoding, HPACK, multiplexing, flow control, GOAWAY and h2c.
- **HTTP/3 and QUIC v1** — QPACK, request streams, packet protection, loss recovery and connection ID rotation. QUIC packet protection on Wasm, Wasm-GC and JavaScript uses an experimental cryptography implementation.
- **Streaming requests and responses** — Read and write bodies incrementally with backpressure, cancellation and trailers. Async service tests run on Native, Wasm and JavaScript. Wasm-GC runs synchronous protocol tests and has compile-only coverage for async services.
- **HTTP policies** — Opt in to authentication, cookies, caching, redirects, retries and content decoding.
- **Native clients and servers** — TCP, UDP, DNS, HTTP clients, connection pools and listeners. **Built-in network adapters are available on Native only.**
- **Native TLS** — TLS over TCP uses OpenSSL 3.x. HTTP/3 handshakes require OpenSSL 3.5 or a later 3.x release. **The built-in OpenSSL adapter is available on Native only.**
- **Host I/O** — Wasm and JavaScript can use `adapter/callback` with host-provided async byte streams. HTTP/3 also requires host datagram transport and a QUIC TLS handshake provider. The library has no built-in browser `fetch` or WebSocket adapter.

## Installation and usage

To install version `0.8.2` in your MoonBit project, run

```sh
moon add ZSeanYves/http@0.8.2
```

The following example runs on all four backends. Import the `protocol/http1` package for tests in `moon.pkg`.

```moonbit
import {
  "ZSeanYves/http/protocol/http1",
} for "test"
```

Add this test to `request_test.mbt` and run `moon test` to parse a request.

```moonbit
test "decode a request" {
  let decoder = @http1.RequestDecoder::new()
  decoder.feed(b"GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n").unwrap()
  guard decoder.next() is Ok(Some(RequestHead(head))) else {
    fail("expected request headers")
  }
  assert_eq(head.uri.value, "/hello")
  assert_true(decoder.next() is Ok(Some(RequestEnd)))
}
```

### First HTTPS GET with the published 0.8.2 package

Use these imports in a Native package's `moon.pkg` and call `get(uri)`. Pass `trust_anchors` to select a PEM trust bundle.

```moonbit
import {
  "ZSeanYves/http/adapter/native/client" @native_client,
  "ZSeanYves/http/adapter/native/tls" @native_tls,
  "ZSeanYves/http/adapter/native/transport" @native_transport,
  "ZSeanYves/http/core/types",
  "ZSeanYves/http/runtime/transport",
}
```

```moonbit
pub async fn get(uri : @types.Uri, trust_anchors? : Bytes) -> Bytes {
  let client = @native_client.new_http1_client(
    @native_transport.NativeResolver::new(),
    @transport.AllowAllPolicy::new(),
    @native_transport.NativeClock::new(),
    @native_tls.NativeTlsProvider::new(),
    origin_tls={ ..@transport.TlsOptions::defaults(), alpn: ["http/1.1"], trust_anchors },
  ).unwrap_or_error()
  defer client.close()
  let response = client.send({
    http_method: Get, uri, version: Http11, headers: @types.HeaderMap::new(), body: b"",
  }).unwrap_or_error()
  guard response.status == 200 else { fail("unexpected HTTP status") }
  response.body
}
```

### Development API in the 0.9.0 candidate

Identify the candidate by its Git SHA and frozen package digest. The distribution gate records both in `_build/evidence/release/<Git SHA>/evidence.json`. Open the relative guides at that same revision. [Native client](adapter/native/client/README.md) · [Native server](adapter/native/server/README.md) · [Changelog](CHANGELOG.md)

| Capability | Native | Wasm and JS | Wasm-GC |
| --- | --- | --- | --- |
| Protocol expert APIs in `core` and `protocol` | Executed | Executed | Executed, including synchronous QUIC vectors |
| Application APIs in `application` and `runtime/service` | Native TCP/UDP, DNS and TLS, four HTTP versions exercised over loopback | Async services and host byte-stream callbacks executed | Async services compile only |
| HTTP/3 deployment | QUIC TLS from OpenSSL 3.x starting with 3.5 | Requires host datagrams and QUIC TLS. Portable packet protection uses experimental cryptography | Same host requirements. Async services compile only |

[Native loopback tests](https://github.com/ZSeanYves/http/blob/main/tests/integration/native_server/scoped_client_test.mbt) · [Host callback tests](https://github.com/ZSeanYves/http/blob/main/tests/blackbox/callback_api/transport_test.mbt) · [Protocol and portable execution checks](https://github.com/ZSeanYves/http/blob/main/repo-tools/tools/check_runtime_tests.mbtx)

## Migrating to this branch

- Observe server events with `ServerEvent` and query the current state with `ServerState`. The former `ServerPhase` enum has been removed.
- Pass `ReplayableBody` for an empty body in redirect and retry decisions. Use `NonReplayableBody` for one-shot uploads.
- `RedirectTracker` keeps its per-method loop detection private. Callers that need a redirect history can record the URI returned by each successful `follow`.
- The low-level HTTP/3 client and service connection functions accept `Some(milliseconds)` or `None` for `handshake_timeout_ms`. Omitting it keeps the 10-second default. The scoped client uses `ClientTimeouts.tls_ms`.

- `HeaderMap::content_length()` returns `UInt64?`. Bodyless HEAD/304 responses also preserve the raw decimal field for larger representation metadata.
- Buffered H1/H2 `execute` returns `BufferedResponse`. Read trailing fields from `trailers` and initial fields from `headers`. The default `ReturnResponse` delivers 3xx. Select `RejectRedirect` or `RedirectPolicy::limited()` for explicit rejection or following.
- The H3 driver's `connection`, `failure` and local stream IDs are accessed through methods. Its `decoders`, `kinds`, `prefixes`, `blocked_frames` and `pending_fin` are private. Observe `blocked_bytes()` and `blocked_stream_count()`. QPACK owns its `blocked` map and `encoder_buffer`. Read `table_size()`, `capacity()`, and `total_inserts()`. Decoder operations return errors and limits are supplied at construction.
- Context-aware Native TLS listener bindings expose the verified client certificate identity. H2 defaults to one connection per origin. Set `max_connections_per_origin` to allow expansion at saturation.
- Range requests preserve encoded 206 representations. The cache orders completed fills by representation version and refreshes SWR hits in the background. H3 applies request and response stage deadlines and H1 drains admitted requests at shutdown.

Validate a frozen checkout with `moon run repo-tools/tools/release_evidence.mbtx`. After publication, run `moon run repo-tools/tools/verify_consumers.mbtx -- --published-candidate` from the frozen release commit to compare registry and archive digests and rerun both consumers in fresh projects.
