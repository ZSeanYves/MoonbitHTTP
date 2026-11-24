# `adapter/native/server`

[English](README.md) · [项目说明](../../../README_zh.md)

仅支持 Native。由应用选择监听端点，并将请求交给自己的处理函数。`NativeTcpListener::bind_http_tls` 按 ALPN 提供 HTTP/1.1 和 HTTP/2；`NativeHttp3Listener::bind_http` 在 UDP 上提供 HTTP/3，使用 TLS 1.3 和 `h3` ALPN。服务端证书与私钥通过 `TlsOptions` 传入。

在 `moon.pkg` 中导入

```moonbit
import {
  "ZSeanYves/MoonbitHTTP/adapter/native/server" @native_server,
  "ZSeanYves/MoonbitHTTP/application/server",
  "ZSeanYves/MoonbitHTTP/runtime/transport",
  "ZSeanYves/MoonbitHTTP/core/types",
  "ZSeanYves/MoonbitHTTP/core/body",
}

supported_targets = "+native"
```

将函数放入调用方包的 `.mbt` 文件中。

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

## 关闭监听器

将 TCP 监听器交给 `ServerSupervisor::serve`。HTTP/3 如上例调用 `listener.serve(supervisor)`。调用 `supervisor.begin_shutdown()` 后停止接收新连接，并向使用请求处理接口的 HTTP/3 对端发送 GOAWAY，已接收的流可在宽限期内完成。如需自行驱动连接事件循环，可使用底层的 `NativeHttp3Listener::bind`。
