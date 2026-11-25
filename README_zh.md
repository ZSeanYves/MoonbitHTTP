# ZSeanYves/http

[English](README.md)

这是 MoonBit 的流式 HTTP 协议库，支持 HTTP/1.0、HTTP/1.1、HTTP/2、HTTP/3 和 QUIC v1。你可以单独使用协议编解码器，也可以将客户端、连接池或服务端监听器接入自己的应用。

## 功能

- **HTTP/1.0 和 HTTP/1.1** — 增量解析和编码请求、响应。HTTP/1.0 默认关闭连接，可显式启用 keep-alive。HTTP/1.1 还支持分块传输和尾部字段。
- **HTTP/2** — 支持帧编解码、HPACK、多路复用、流量控制、GOAWAY 和 h2c。
- **HTTP/3 与 QUIC v1** — 支持 QPACK、请求流、包保护、丢包恢复和连接 ID 轮换。Wasm、Wasm-GC 和 JavaScript 的 QUIC 包保护使用实验性密码实现。
- **流式请求与响应** — 支持分段读写正文、背压、取消和尾部字段。Native、Wasm 和 JavaScript 已运行异步服务测试；Wasm-GC 已运行同步协议测试，异步服务仅验证编译。
- **HTTP 策略** — 可按需启用认证、Cookie、缓存、重定向、重试和内容解码。
- **原生客户端与服务端** — 提供 TCP、UDP、DNS、HTTP 客户端、连接池和监听器。**仅 Native 支持内置网络适配器。**
- **原生 TLS** — TCP 上的 TLS 使用 OpenSSL 3.x；HTTP/3 的 QUIC TLS 握手需要 OpenSSL 3.5 或更高的 3.x 版本。**仅 Native 支持内置 OpenSSL 适配器。**
- **宿主 I/O 接入** — Wasm 和 JavaScript 可通过 `adapter/callback` 接入宿主提供的异步字节流。HTTP/3 还需宿主提供数据报传输和 QUIC TLS 握手能力。当前没有内置的浏览器 `fetch` 或 WebSocket 适配器。

## 安装与使用

在 MoonBit 项目中安装 `0.8.2` 版本：

```sh
moon add ZSeanYves/http@0.8.2
```

下面的例子在四个后端都可以运行。先在 `moon.pkg` 中为测试导入 `protocol/http1` 包：

```moonbit
import {
  "ZSeanYves/http/protocol/http1",
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

### 正式版 0.8.2 的首次 HTTPS GET

将下列导入写入 Native 包的 `moon.pkg`，然后调用 `get(uri)`。传入 `trust_anchors` 可使用指定的 PEM 根证书。

```moonbit
import {
  "ZSeanYves/http/adapter/native/client" @native_client,
  "ZSeanYves/http/adapter/native/tls" @native_tls,
  "ZSeanYves/http/adapter/native/transport" @native_transport,
  "ZSeanYves/http/core/types",
  "ZSeanYves/http/runtime/transport",
}
```

```moonbit
pub async fn get(uri : @types.Uri, trust_anchors? : Bytes) -> Bytes {
  let client = @native_client.new_http1_client(
    @native_transport.NativeResolver::new(),
    @transport.AllowAllPolicy::new(),
    @native_transport.NativeClock::new(),
    @native_tls.NativeTlsProvider::new(),
    origin_tls={ ..@transport.TlsOptions::defaults(), alpn: ["http/1.1"], trust_anchors },
  ).unwrap_or_error()
  defer client.close()
  let response = client.send({
    http_method: Get, uri, version: Http11, headers: @types.HeaderMap::new(), body: b"",
  }).unwrap_or_error()
  guard response.status == 200 else { fail("unexpected HTTP status") }
  response.body
}
```

### 开发版 0.9.0 候选接口

本次候选通过提交 SHA 与冻结包摘要标识。独立消费作业在 `_build/evidence/release/<提交 SHA>/evidence.json` 记录两者。请从相同 Git 修订打开以下相对链接。[Native 客户端](adapter/native/client/README_zh.md) · [Native 服务端](adapter/native/server/README_zh.md) · [更新日志](CHANGELOG.md)

应用开发入口为 `adapter/native/client`、`adapter/native/server`、`application/{client,server}`、`core/{body,types}` 和 `policy/{auth,cache,content_coding,cookie}`。自建传输或实现协议时使用 `runtime/{transport,service,detection}`、`adapter/callback`、`adapter/native/{tls,transport}`、`core/codec` 和 `protocol/{http1,http2,http3,quic,tls}`。Native 以外的 QUIC 包保护使用实验性便携密码实现。

| 能力 | Native | Wasm 与 JS | Wasm-GC |
|---|---|---|---|
| 协议编解码与 QUIC 包保护 | [已运行](https://github.com/ZSeanYves/http/blob/e91603e/repo-tools/tools/check_runtime_tests.mbtx) | [已运行](https://github.com/ZSeanYves/http/blob/e91603e/repo-tools/tools/check_runtime_tests.mbtx) | [已运行同步协议向量](https://github.com/ZSeanYves/http/blob/e91603e/repo-tools/tools/check_runtime_tests.mbtx) |
| 应用与流式服务 | [原生 TCP/UDP、DNS、TLS，四个 HTTP 版本通过回环测试](https://github.com/ZSeanYves/http/blob/e91603e/tests/integration/native_server/scoped_client_test.mbt) | [已运行异步服务](https://github.com/ZSeanYves/http/blob/e91603e/repo-tools/tools/check_runtime_tests.mbtx)及[宿主字节流回调](https://github.com/ZSeanYves/http/blob/e91603e/tests/blackbox/callback_api/transport_test.mbt) | 异步服务仅编译 |
| 部署 HTTP/3 | [经身份验证的 QUIC，使用 3.5 起的 OpenSSL 3.x](https://github.com/ZSeanYves/http/blob/e91603e/tests/integration/native_server/scoped_client_test.mbt) | 需提供宿主数据报与 QUIC TLS。[便携包保护向量](https://github.com/ZSeanYves/http/blob/e91603e/repo-tools/tools/check_runtime_tests.mbtx) | 同样需要宿主支持，[同步 QUIC 向量已运行](https://github.com/ZSeanYves/http/blob/e91603e/repo-tools/tools/check_runtime_tests.mbtx)。异步服务仅编译 |

## 本分支的接口迁移

- 用 `ServerEvent` 观察服务端事件，用 `ServerState` 查询当前状态。原来的 `ServerPhase` 已移除。
- 直接调用重试或重定向策略时，用 `ReplayableBody` 表示空正文。一次性上传使用 `NonReplayableBody`。
- `RedirectTracker` 内部维护当前方法的循环检测集合。需要完整历史时，调用者可记录每次 `follow` 返回的目标 URI。
- 底层 HTTP/3 客户端与服务连接的 `handshake_timeout_ms` 接受 `Some(毫秒数)` 或 `None`。省略时仍为 10 秒。高层客户端沿用 `ClientTimeouts.tls_ms`。

- `HeaderMap::content_length()` 返回 `UInt64?`，无正文的 HEAD/304 仍可按原始十进制字段读取大对象元数据。
- H1/H2 的缓冲 `execute` 返回 `BufferedResponse`。从 `trailers` 取尾部字段，`headers` 保留初始字段。默认 `ReturnResponse` 交付 3xx，显式使用 `RejectRedirect` 或 `RedirectPolicy::limited()` 选择其他行为。
- H3 驱动的 `connection`、`failure` 及各本地流 ID 改用同名方法。`decoders`、`kinds`、`prefixes`、`blocked_frames` 和 `pending_fin` 已封装；使用 `blocked_bytes()`、`blocked_stream_count()` 诊断。QPACK 的 `blocked`、`encoder_buffer` 改由解码器管理，用 `table_size()`、`capacity()`、`total_inserts()` 读数，用解码结果判断错误。`limits` 在构造时提供。
- 原生 TLS 的上层 handler 可以使用带上下文的绑定入口读取已经验证的客户端证书身份。H2 同源连接数默认 1，通过 `max_connections_per_origin` 配置饱和时扩容。
- Range 请求保留 206 编码表示。缓存按版本提交并在 SWR 命中时后台刷新。H3 接入请求和响应各阶段时限，H1 停服后结束已接纳请求。

核验候选包运行 `moon run repo-tools/tools/release_evidence.mbtx`。正式发布后在冻结发行提交运行 `moon run repo-tools/tools/verify_consumers.mbtx -- --published-candidate`。它将注册表归档摘要与同一提交的冻结摘要比对，并在空项目重跑两个版本的消费者。
