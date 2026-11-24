# `adapter/native/transport`

[English](README.md) · [项目说明](../../../README_zh.md)

仅支持 Native。`TcpConnector` 连接数字 IP 端点，调用方负责在域名解析前和连接各候选地址前检查网络策略。UDP 套接字接口直接接收策略。`NativeResolver` 按系统顺序返回解析结果，对数字 IP 跳过 DNS。`NativeClock` 提供单调时钟和系统时间。

在 `moon.pkg` 中导入

```moonbit
import {
  "moonbitlang/core/async",
  "ZSeanYves/MoonbitHTTP/adapter/native/transport" @native_transport,
  "ZSeanYves/MoonbitHTTP/runtime/transport",
} for "test"

supported_targets = "+native"

options(
  "allow-experimental-packages": ["moonbitlang/core/async"],
)
```

将示例保存为 `example_test.mbt`。

```moonbit
async test "resolve a numeric loopback address" {
  let resolver = @native_transport.NativeResolver::new()
  let addresses = resolver
    .resolve("127.0.0.1", @transport.ResolveOptions::defaults())
    .unwrap()
  assert_eq(addresses.length(), 1)
}
```
