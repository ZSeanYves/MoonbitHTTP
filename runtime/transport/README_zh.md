# `runtime/transport`

[English](README.md) · [项目说明](../../README_zh.md)

定义字节流连接、数据报 I/O、DNS、网络策略、时钟和 TLS 握手接口。调用方可接入宿主实现，也可使用 Native 适配器。QUIC 的 TLS 身份应使用 HTTPS 源站名称，即使数据报端点使用数字 IP 地址。

宿主已经提供异步字节流读写时，可用 `CallbackTransport` 将回调接入传输层。[宿主回调适配器](../../adapter/callback/README_zh.md)

在 `moon.pkg` 中导入

```moonbit
import {
  "ZSeanYves/http/runtime/transport",
} for "test"
```

将示例保存为 `example_test.mbt`。

```moonbit
test "configure QUIC for an HTTPS origin" {
  let options = @transport.TlsOptions::for_quic("example.com")
  assert_eq(options.server_name, Some("example.com"))
  assert_eq(options.alpn, ["h3"])
}
```
