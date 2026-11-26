# `adapter/native/client`

[中文](README_zh.md) · [Project README](../../../README.md)

Select an HTTP version and network policy in `with_client`. The factory supplies DNS, TCP or UDP, TLS and the system clock. Reuse the client for multiple or concurrent requests within the callback.

Add these imports to `moon.pkg`.

```moonbit
import {
  "ZSeanYves/http/adapter/native/client" @native_client,
  "ZSeanYves/http/application/client",
  "ZSeanYves/http/core/body",
  "ZSeanYves/http/core/types",
  "ZSeanYves/http/runtime/transport",
}
supported_targets = "+native"
```

```moonbit
pub async fn get(uri : @types.Uri, trust_anchors? : Bytes) -> Bytes {
  @native_client.with_client(
    async fn(client) {
      let response = client.send(client.request(Get, uri, @client.Upload::bytes(b"")))
      @body.collect(response.body, max_bytes=1024 * 1024).0
    },
    version=Http11,
    tls={ ..@transport.TlsOptions::defaults(), alpn: ["http/1.1"], trust_anchors },
    policy=@transport.AllowAllPolicy::new(),
  )
}
```

The example policy allows all network access. Supply your application's policy where appropriate. HTTP/1 supports forward proxies and CONNECT tunnels. HTTP/2 uses h2 ALPN over TLS or prior knowledge on cleartext connections. HTTP/3 requires an authenticated HTTPS origin. Exiting the callback releases unread responses and the pool.

Use `with_http2_pool`, `with_http3_pool` or `with_http3_client_connection` for protocol-specific tuning and direct exchanges.
