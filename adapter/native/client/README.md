# `adapter/native/client`

[中文](README_zh.md) · [Project README](../../../README.md)

Select an HTTP version and network policy in `with_client`. The factory supplies DNS, TCP or UDP, TLS and the system clock. Reuse the client for multiple or concurrent requests within the callback.

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

The example imports `adapter/native/client` as `native_client`, `application/client`, `core/types`, `core/body` and `runtime/transport`. The example policy allows all network access. Supply your application's policy where appropriate. HTTP/1 supports forward and CONNECT proxies. HTTP/2 uses h2 ALPN over TLS or prior knowledge on cleartext connections. HTTP/3 requires an authenticated HTTPS origin. Exiting the callback releases unread responses and the pool.

Use `with_http2_pool`, `with_http3_pool` or `with_http3_client_connection` for protocol-specific tuning and direct exchanges.
