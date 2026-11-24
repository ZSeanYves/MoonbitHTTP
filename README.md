# MoonbitHTTP

[中文](README_zh.md)

MoonbitHTTP is a streaming HTTP library for MoonBit. It supports HTTP/1.1, HTTP/2, HTTP/3 and QUIC v1. Use the protocol codecs on their own, or integrate a client, connection pool or server listener into your application.

## Features

- **HTTP/1.1** — Incremental request and response parsing and encoding, chunked transfer, trailers and connection reuse.
- **HTTP/2** — Frame encoding and decoding, HPACK, multiplexing, flow control, GOAWAY and h2c.
- **HTTP/3 and QUIC v1** — QPACK, request streams, packet protection, loss recovery and connection ID rotation. QUIC packet protection on Wasm, Wasm-GC and JavaScript uses an experimental cryptography implementation.
- **Streaming requests and responses** — Read and write bodies incrementally with backpressure, cancellation and trailers. Async service tests run on Native, Wasm and JavaScript. Wasm-GC runs synchronous protocol tests and has compile-only coverage for async services.
- **HTTP policies** — Opt in to authentication, cookies, caching, redirects, retries and content decoding.
- **Native clients and servers** — TCP, UDP, DNS, HTTP clients, connection pools and listeners. **Built-in network adapters are available on Native only.**
- **Native TLS** — TLS over TCP uses OpenSSL 3.x. HTTP/3 handshakes require OpenSSL 3.5 or a later 3.x release. **The built-in OpenSSL adapter is available on Native only.**
- **Host I/O** — Wasm and JavaScript can use `adapter/callback` with host-provided async byte streams. HTTP/3 also requires host datagram transport and a QUIC TLS handshake provider. The library has no built-in browser `fetch` or WebSocket adapter.

## Installation and usage

Install the published `0.7.0` release in your MoonBit project.

```sh
moon add ZSeanYves/MoonbitHTTP@0.7.0
```

The following example runs on all four backends. Import the HTTP/1.1 package for tests in `moon.pkg`.

```moonbit
import {
  "ZSeanYves/MoonbitHTTP/protocol/http1",
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

The Native client and server entry points have changed since `0.7.0`. For the current source API, see how to send requests, configure pools and bind listeners in the package guides. [Native client](adapter/native/client/README.md) · [Native server](adapter/native/server/README.md) · [Changelog](CHANGELOG.md)
