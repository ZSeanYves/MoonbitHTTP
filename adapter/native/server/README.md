# `adapter/native/server`

[中文](README_zh.md) · [Project README](../../../README.md)

Native only. Bind a listener to an application-selected endpoint and route requests to your handler. `NativeTcpListener::bind_http_tls` serves HTTP/1.1 and HTTP/2 according to ALPN. `NativeHttp3Listener::bind_http` serves HTTP/3 over UDP with TLS 1.3 and `h3` ALPN. Pass server credentials in `TlsOptions`.

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
