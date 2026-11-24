# MoonbitHTTP

[English](README.md)

MoonbitHTTP 是 MoonBit 的流式 HTTP 协议库，支持 HTTP/1.1、HTTP/2、HTTP/3 和 QUIC v1。你可以单独使用协议编解码器，也可以将客户端、连接池或服务端监听器接入自己的应用。

## 功能

- **HTTP/1.1** — 增量解析和编码请求、响应，支持分块传输、尾部字段和连接复用。
- **HTTP/2** — 支持帧编解码、HPACK、多路复用、流量控制、GOAWAY 和 h2c。
- **HTTP/3 与 QUIC v1** — 支持 QPACK、请求流、包保护、丢包恢复和连接 ID 轮换。Wasm、Wasm-GC 和 JavaScript 的 QUIC 包保护使用实验性密码实现。
- **流式请求与响应** — 支持分段读写正文、背压、取消和尾部字段。Native、Wasm 和 JavaScript 已运行异步服务测试；Wasm-GC 已运行同步协议测试，异步服务仅验证编译。
- **HTTP 策略** — 可按需启用认证、Cookie、缓存、重定向、重试和内容解码。
- **原生客户端与服务端** — 提供 TCP、UDP、DNS、HTTP 客户端、连接池和监听器。**仅 Native 支持内置网络适配器。**
- **原生 TLS** — TCP 上的 TLS 使用 OpenSSL 3.x；HTTP/3 的 QUIC TLS 握手需要 OpenSSL 3.5 或更高的 3.x 版本。**仅 Native 支持内置 OpenSSL 适配器。**
- **宿主 I/O 接入** — Wasm 和 JavaScript 可通过 `adapter/callback` 接入宿主提供的异步字节流。HTTP/3 还需宿主提供数据报传输和 QUIC TLS 握手能力。当前没有内置的浏览器 `fetch` 或 WebSocket 适配器。

## 安装与使用

在 MoonBit 项目中安装已发布的 `0.7.0`：

```sh
moon add ZSeanYves/MoonbitHTTP@0.7.0
```

下面的例子在四个后端都可以运行。先在 `moon.pkg` 中为测试导入 HTTP/1.1 包：

```moonbit
import {
  "ZSeanYves/MoonbitHTTP/protocol/http1",
} for "test"
```

在 `request_test.mbt` 中解析一条请求，然后运行 `moon test`：

```moonbit
test "decode a request" {
  let decoder = @http1.RequestDecoder::new()
  decoder.feed(b"GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n").unwrap()
  guard decoder.next() is Ok(Some(RequestHead(head))) else {
    fail("expected request headers")
  }
  assert_eq(head.uri.value, "/hello")
  assert_true(decoder.next() is Ok(Some(RequestEnd)))
}
```

当前源码的 Native 客户端和服务端入口已有调整。发送请求、配置连接池或绑定监听地址，可参阅对应的包文档。[客户端用法](adapter/native/client/README_zh.md) · [服务端用法](adapter/native/server/README_zh.md) · [更新日志](CHANGELOG.md)
