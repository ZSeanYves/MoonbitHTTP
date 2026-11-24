# `adapter/native/client`

[English](README.md) · [项目说明](../../../README_zh.md)

仅支持 Native。`new_http1_client` 接收解析器、网络策略、时钟和 TLS 提供方，构造可复用的 HTTP/1.1 客户端。可在多个请求之间共享，使用结束时调用 `close`。HTTP/2 和 HTTP/3 可分别用 `with_http2_pool` 和 `with_http3_pool` 在作用域内共享多路复用连接。

在 `moon.pkg` 中导入

```moonbit
import {
  "ZSeanYves/MoonbitHTTP/adapter/native/client" @native_client,
  "ZSeanYves/MoonbitHTTP/adapter/native/tls" @native_tls,
  "ZSeanYves/MoonbitHTTP/adapter/native/transport" @native_transport,
  "ZSeanYves/MoonbitHTTP/runtime/transport",
  "ZSeanYves/MoonbitHTTP/application/client",
}

supported_targets = "+native"
```

将函数放入调用方包的 `.mbt` 文件中。

```moonbit
pub fn[P : @transport.NetworkPolicy] new_client(
  policy : P,
) -> Result[@client.Http1Client, @client.ClientError] {
  @native_client.new_http1_client(
    @native_transport.NativeResolver::new(),
    policy,
    @native_transport.NativeClock::new(),
    @native_tls.NativeTlsProvider::new(),
  )
}
```

## HTTP/3 连接

单个 HTTPS 源站使用 `with_http3_client_connection`，多个源站使用 `with_http3_pool`。上传完成前即可收到响应，应在作用域内读完或取消。UDP 对端使用域名时传入 `resolver=Some(resolver)`，并将 HTTPS 源站的主机名传给 `TlsOptions::for_quic`。逻辑端口与 UDP 端口不同时设置 `origin_port`。握手中和排空中的连接均计入池的 `max_connections`，收到 GOAWAY 后由应用决定是否重新发送请求。

使用工厂返回的客户端发送请求，见 [HTTP/1.1 请求示例](../../../application/client/README_zh.md)。
