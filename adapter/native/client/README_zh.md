# `adapter/native/client`

[English](README.md) · [项目说明](../../../README_zh.md)

在 `with_client` 中显式选择 HTTP 版本和网络策略。工厂提供 DNS、TCP 或 UDP、TLS 及本机时钟。回调中可重复或并发使用同一个客户端。

```moonbit
pub async fn get(uri : @types.Uri) -> Bytes {
  @native_client.with_client(
    async fn(client) {
      let response = client.send(client.request(Get, uri, @client.Upload::bytes(b"")))
      @body.collect(response.body, max_bytes=1024 * 1024).0
    },
    version=Http11,
    policy=@transport.AllowAllPolicy::new(),
  )
}
```

示例使用 `adapter/native/client`（别名 `native_client`）、`application/client`、`core/types`、`core/body` 和 `runtime/transport`。示例策略允许所有网络访问，可传入应用自己的策略。H1 支持现有的代理模式。H2 的 HTTPS 连接需要协商 h2，明文使用先验知识。H3 使用已验证的 HTTPS 源站和 QUIC TLS。回调退出时释放未读响应和连接池。

高级调用方仍可使用 `with_http2_pool`、`with_http3_pool` 和 `with_http3_client_connection` 选择专属参数或直接管理协议交换。
