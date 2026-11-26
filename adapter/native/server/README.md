# `adapter/native/server`

[中文](README_zh.md) · [Project README](../../../README.md)

Native only. Bind a listener to an application-selected endpoint and route requests to your handler. `NativeTcpListener::bind_http_tls` serves HTTP/1.1 and HTTP/2 according to ALPN. `NativeHttp3Listener::bind_http` serves HTTP/3 over UDP with TLS 1.3 and `h3` ALPN. Pass server credentials in `TlsOptions`.

If the TCP listener fails to accept a connection, inspect `ServerSupervisor::last_accept_error()` for the underlying cause. [Supervisor and shutdown](../../../application/server/README.md)

Without an explicit service configuration the TLS listener reads up to one 16 KiB TLS record at a time and advertises a 256 KiB HTTP/2 receive window shared across streams. Each stream is also limited to 256 KiB. Pass `config` to choose a smaller window or a different read size.

In `moon.pkg`

```moonbit
import {
  "ZSeanYves/http/adapter/native/server" @native_server,
  "ZSeanYves/http/application/server",
  "ZSeanYves/http/runtime/transport",
  "ZSeanYves/http/core/types",
  "ZSeanYves/http/core/body",
}

supported_targets = "+native"
```

Add this function to a `.mbt` file in the importing package.

```moonbit
pub async fn[P : @transport.NetworkPolicy] serve_h3(
  endpoint : @types.Endpoint,
  policy : P,
  tls : @transport.TlsOptions,
  supervisor : @server.ServerSupervisor,
) -> Unit {
  let listener = @native_server.NativeHttp3Listener::bind_http(
    endpoint,
    policy,
    tls,
    fn(request) {
      {
        status: 200,
        version: request.version,
        headers: @types.HeaderMap::new(),
        body: @body.FullBody::new(b"ok"),
      }
    },
  ).unwrap_or_error()
  defer listener.close()
  listener.serve(supervisor).unwrap_or_error()
}
```

## Shutdown

Pass a TCP listener to `ServerSupervisor::serve`. For HTTP/3, call `listener.serve(supervisor)` as above. Calling `supervisor.begin_shutdown()` stops admission and sends GOAWAY to typed HTTP/3 peers. Accepted streams can finish until the grace deadline. Use the lower-level `NativeHttp3Listener::bind` when you need to own the connection event loop.

Use `NativeTcpListener::bind_http_tls_with_context` or `NativeHttp3Listener::bind_http_with_context` to receive a `RequestContext` alongside the request. With required client authentication the verified leaf carries a 32-byte SHA-256 fingerprint and its DNS, URI, email and IP subject alternative names. The IP value contains four or sixteen octets in network order. The certificate is absent on one-way TLS. Applications own authorization policy; HTTP header values cannot supply the connection identity.

A native HTTP/3 connection can survive UDP source-port changes on the same IP. The listener authenticates 1-RTT traffic, validates the new path, and keeps the previous path usable while verification is pending. Cross-IP migration is outside the native listener’s supported deployment profile.
