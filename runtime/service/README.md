# `runtime/service`

[中文](README_zh.md) · [Project README](../../README.md)

Run HTTP/1.1, HTTP/2 and HTTP/3 on supplied connection I/O. Stream drivers handle framing, body backpressure and cancellation. `serve_http1_connection` accepts a reader, a writer and your request handler. For HTTP/3, supply a QUIC session and its datagram event source. The application owns the listener and chooses when to drain connections.

In `moon.pkg`

```moonbit
import {
  "moonbitlang/core/async/io" @aio,
  "ZSeanYves/MoonbitHTTP/runtime/service",
  "ZSeanYves/MoonbitHTTP/core/types",
  "ZSeanYves/MoonbitHTTP/core/body",
}

options(
  "allow-experimental-packages": ["moonbitlang/core/async/io"],
)
```

Add this function to a `.mbt` file in the importing package.

```moonbit
pub async fn[R : @aio.BinaryReader, W : @aio.BinaryWriter] serve(
  reader : R,
  writer : W,
) -> Unit {
  @service.serve_http1_connection(reader, writer, fn(request) {
    {
      status: 200,
      version: request.version,
      headers: @types.HeaderMap::new(),
      body: @body.FullBody::new(b"ok"),
    }
  })
}
```

## Serving connections

Use `serve_http1_or_h2c_connection` for cleartext HTTP/1.1 and HTTP/2 on one listener. For a pending upload with `Expect: 100-continue`, the servers can send 100 before reading the body. Unsupported expectations get 417 before the handler runs.

With HTTP/3, `with_http3_connection` drives the handshake, receive loop and recovery timer. Use `serve_http3_connection(io, handler)` for per-request dispatch and `on_request_error` to observe handler failures. For graceful shutdown, share a `ServerShutdown` across the typed connections, call `begin()` and enforce the grace deadline in the application.
